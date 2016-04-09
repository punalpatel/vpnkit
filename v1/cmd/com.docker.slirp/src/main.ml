(*
 * Copyright (C) 2016 David Scott <dave.scott@docker.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)
open Lwt

let src =
  let src = Logs.Src.create "usernet" ~doc:"Mirage TCP/IP <-> socket proxy" in
  Logs.Src.set_level src (Some Logs.Debug);
  src

module Log = (val Logs.src_log src : Logs.LOG)

let client_macaddr = Macaddr.of_string_exn "C0:FF:EE:C0:FF:EE"
(* random MAC from https://www.hellion.org.uk/cgi-bin/randmac.pl *)
let server_macaddr = Macaddr.of_string_exn "F6:16:36:BC:F9:C6"

let finally f g =
  Lwt.catch (fun () -> f () >>= fun r -> g () >>= fun () -> return r) (fun e -> g () >>= fun () -> fail e)

let or_failwith = function
  | Result.Error (`Msg m) -> failwith m
  | Result.Ok x -> x

let print_pcap = function
  | None -> "disabled"
  | Some (file, None) -> "capturing to " ^ file ^ " with no limit"
  | Some (file, Some limit) -> "capturing to " ^ file ^ " but limited to " ^ (Int64.to_string limit)

let start_slirp socket_path port_control_path pcap_settings peer_ip local_ip =
  Log.info (fun f -> f "Starting slirp server socket_path:%s port_control_path:%s pcap_settings:%s peer_ip:%s local_ip:%s"
    socket_path port_control_path (print_pcap @@ Active_config.hd pcap_settings) (Ipaddr.V4.to_string peer_ip) (Ipaddr.V4.to_string local_ip)
  );
  let config = Tcpip_stack.make ~client_macaddr ~server_macaddr ~peer_ip ~local_ip in

  (* Start the 9P port forwarding server *)
  let module Ports = Active_list.Make(Forward.Make(Tcpip_stack)) in
  let module Server = Server9p_unix.Make(Log9p_unix.Stdout)(Ports) in
  let fs = Ports.make () in
  Osx_socket.listen port_control_path
  >>= fun port_s ->
  let server = Server.of_fd fs port_s in
  Lwt.async (fun () -> Server.serve_forever server);

  Log.info (fun f -> f "Starting slirp network stack on %s" socket_path);
  Osx_socket.listen socket_path
  >>= fun s ->
    let rec loop () =
      Lwt_unix.accept s
      >>= fun (client, _) ->
      Vmnet.of_fd ~client_macaddr ~server_macaddr client
      >>= function
       | `Error (`Msg m) -> failwith m
       | `Ok x ->
        Log.debug (fun f -> f "accepted vmnet connection");
        let rec monitor_pcap_settings pcap_settings =
          Active_config.tl pcap_settings
          >>= fun pcap_settings ->
          ( match Active_config.hd pcap_settings with
            | None ->
              Log.debug (fun f -> f "Disabling any active packet capture");
              Vmnet.stop_capture x
            | Some (filename, size_limit) ->
              Log.debug (fun f -> f "Capturing packets to %s %s" filename (match size_limit with None -> "with no limit" | Some x -> Printf.sprintf "limited to %Ld bytes" x));
              Vmnet.start_capture x ?size_limit filename )
          >>= fun () ->
          monitor_pcap_settings pcap_settings in
        Lwt.async (fun () -> Utils.log_exception_continue "monitor_pcap_settings" (fun () -> monitor_pcap_settings pcap_settings));

        begin Tcpip_stack.connect ~config x
        >>= function
        | `Error (`Msg m) -> failwith m
        | `Ok s ->
            Ports.set_context fs s;
            Tcpip_stack.listen_udpv4 s 53 (Dns_forward.input s);
            Vmnet.add_listener x (
              fun buf ->
                match (Wire_structs.parse_ethernet_frame buf) with
                | Some (Some Wire_structs.IPv4, _, payload) ->
                  let src = Ipaddr.V4.of_int32 @@ Wire_structs.Ipv4_wire.get_ipv4_src payload in
                  let dst = Ipaddr.V4.of_int32 @@ Wire_structs.Ipv4_wire.get_ipv4_dst payload in
                  begin match Wire_structs.Ipv4_wire.(int_to_protocol @@ get_ipv4_proto payload) with
                    | Some `UDP ->
                      let udp = Cstruct.shift payload Wire_structs.Ipv4_wire.sizeof_ipv4 in
                      let src_port = Wire_structs.get_udp_source_port udp in
                      let dst_port = Wire_structs.get_udp_dest_port udp in
                      let length = Wire_structs.get_udp_length udp in
                      let payload = Cstruct.sub udp Wire_structs.sizeof_udp (length - Wire_structs.sizeof_udp) in
                      (* We handle DNS on port 53 ourselves *)
                      if dst_port <> 53 then begin
                        Log.debug (fun f -> f "UDP %s:%d -> %s:%d len %d"
                                     (Ipaddr.V4.to_string src) src_port
                                     (Ipaddr.V4.to_string dst) dst_port
                                     length
                                 );
                        let reply buf = Tcpip_stack.UDPV4.writev ~source_ip:dst ~source_port:dst_port ~dest_ip:src ~dest_port:src_port (Tcpip_stack.udpv4 s) [ buf ] in
                        Socket.UDPV4.input ~reply ~src:(src, src_port) ~dst:(dst, dst_port) ~payload
                      end else Lwt.return_unit
                    | _ -> Lwt.return_unit
                  end
                | _ -> Lwt.return_unit
            );
            Tcpip_stack.listen_tcpv4_flow s (
              fun ~src:(src_ip, src_port) ~dst:(dst_ip, dst_port) ->
                let description =
                  Printf.sprintf "TCP %s:%d > %s:%d"
                    (Ipaddr.V4.to_string src_ip) src_port
                    (Ipaddr.V4.to_string dst_ip) dst_port in
                Log.debug (fun f -> f "%s connecting" description);

                Socket.TCPV4.connect_v4 src_ip src_port
                >>= function
                | `Error (`Msg m) ->
                  Log.info (fun f -> f "%s rejected: %s" description m);
                  return `Reject
                | `Ok remote ->
                  Lwt.return (`Accept (fun local ->
                      finally (fun () ->
                          (* proxy between local and remote *)
                          Log.debug (fun f -> f "%s connected" description);
                          Mirage_flow.proxy (module Clock) (module Tcpip_stack.TCPV4_half_close) local (module Socket.TCPV4) remote ()
                          >>= function
                          | `Error (`Msg m) ->
                            Log.err (fun f -> f "%s proxy failed with %s" description m);
                            return ()
                          | `Ok (l_stats, r_stats) ->
                            Log.debug (fun f ->
                                f "%s closing: l2r = %s; r2l = %s" description
                                  (Mirage_flow.CopyStats.to_string l_stats) (Mirage_flow.CopyStats.to_string r_stats)
                              );
                            return ()
                        ) (fun () ->
                          Socket.TCPV4.close remote
                          >>= fun () ->
                          Log.debug (fun f -> f "%s Socket.TCPV4.close" description);
                          Lwt.return ()
                        )
                    ))
            );
            Tcpip_stack.listen s
            >>= fun () ->
            Log.info (fun f -> f "TCP/IP ready");
            loop ()
        end in
    loop ()
    >>= fun r ->
    Lwt.return (or_failwith r)

let start_native port_control_path =
  Log.info (fun f -> f "starting in native mode port_control_path:%s" port_control_path);
  (* Start the 9P port forwarding server *)
  let module Ports = Active_list.Make(Forward.Make(Socket_stack)) in
  let module Server = Server9p_unix.Make(Log9p_unix.Stdout)(Ports) in
  let fs = Ports.make () in
  Socket_stack.connect ()
  >>= function
  | `Error (`Msg m) ->
    Log.err (fun f -> f "Failed to create a socket stack: %s" m);
    exit 1
  | `Ok s ->
  Ports.set_context fs s;
  Osx_socket.listen port_control_path
  >>= fun port_s ->
  let server = Server.of_fd fs port_s in
  Server.serve_forever server
  >>= fun r ->
  Lwt.return (or_failwith r)

let restart_on_change name to_string values =
  Active_config.tl values
  >>= fun values ->
  let v = Active_config.hd values in
  Log.info (fun f -> f "%s changed to %s in the database: restarting" name (to_string v));
  exit 1

let main_t socket_path slirp_port_control_path vmnet_port_control_path db_path debug =
  Osx_reporter.install ~stdout:debug;
  Log.info (fun f -> f "Setting handler to ignore all SIGPIPE signals");
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  Printexc.record_backtrace true;

  let config = Active_config.create "unix" db_path in
  let driver = [ "com.docker.driver.amd64-linux" ] in

  let pcap_path = driver @ [ "slirp"; "capture" ] in
  Active_config.string_option config pcap_path
  >>= fun string_pcap_settings ->
  let parse_pcap = function
    | None -> Lwt.return None
    | Some x ->
      begin match Stringext.split (String.trim x) ~on:':' with
      | [ filename ] ->
        (** Assume 10MiB limit for safety *)
        Lwt.return (Some (filename, Some 16777216L))
      | [ filename; limit ] ->
        let limit =
          try
            Int64.of_string limit
          with
          | _ -> 16777216L in
        let limit = if limit = 0L then None else Some limit in
        Lwt.return (Some (filename, limit))
      | _ ->
        Lwt.return None
      end in
  Active_config.map parse_pcap string_pcap_settings
  >>= fun pcap_settings ->

  let peer_ips_path = driver @ [ "slirp"; "docker" ] in
  let parse_ipv4 default x = match Ipaddr.V4.of_string @@ String.trim x with
    | None ->
      Log.err (fun f -> f "Failed to parse IPv4 address '%s', using default of %s" x (Ipaddr.V4.to_string default));
      Lwt.return default
    | Some x -> Lwt.return x in
  let default_peer = "192.168.64.2" in
  let default_host = "192.168.64.1" in
  Active_config.string config ~default:default_peer peer_ips_path
  >>= fun string_peer_ips ->
  Active_config.map (parse_ipv4 (Ipaddr.V4.of_string_exn default_peer)) string_peer_ips
  >>= fun peer_ips ->
  Lwt.async (fun () -> restart_on_change "slirp/docker" Ipaddr.V4.to_string peer_ips);

  let host_ips_path = driver @ [ "slirp"; "host" ] in
  Active_config.string config ~default:default_host host_ips_path
  >>= fun string_host_ips ->
  Active_config.map (parse_ipv4 (Ipaddr.V4.of_string_exn default_host)) string_host_ips
  >>= fun host_ips ->
  Lwt.async (fun () -> restart_on_change "slirp/host" Ipaddr.V4.to_string host_ips);

  let peer_ip = Active_config.hd peer_ips in
  let local_ip = Active_config.hd host_ips in

  Lwt.join [
    start_slirp socket_path slirp_port_control_path pcap_settings peer_ip local_ip;
    start_native vmnet_port_control_path;
  ]

let main socket slirp_control vmnet_control db debug = Lwt_main.run @@ main_t socket slirp_control vmnet_control db debug

open Cmdliner

let socket =
  Arg.(value & opt string "/var/tmp/com.docker.slirp.socket" & info [ "socket" ] ~docv:"SOCKET")

let slirp_port_control_path =
  Arg.(value & opt string "/var/tmp/com.docker.slirp.port.socket" & info [ "slirp-port-control" ] ~docv:"PORT")

let vmnet_port_control_path =
  Arg.(value & opt string "/var/tmp/com.docker.vmnet.port.socket" & info [ "vmnet-port-control" ] ~docv:"PORT")

let db_path =
  Arg.(value & opt string "/var/tmp/com.docker.db.socket" & info [ "db" ] ~docv:"DB")

let debug =
  let doc = "Verbose debug logging to stdout" in
  Arg.(value & flag & info [ "debug" ] ~doc)

let command =
  let doc = "proxy TCP/IP connections from an ethernet link via sockets" in
  let man =
    [`S "DESCRIPTION";
     `P "Terminates TCP/IP and UDP/IP connections from a client and proxy the
		     flows via userspace sockets"]
  in
  Term.(pure main $ socket $ slirp_port_control_path $ vmnet_port_control_path $ db_path $ debug),
  Term.info "proxy" ~doc ~man

let () =
  Printexc.record_backtrace true;
  match Term.eval command with
  | `Error _ -> exit 1
  | _ -> exit 0
