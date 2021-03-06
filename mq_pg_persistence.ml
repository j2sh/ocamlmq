(* Copyright (c) 2010 Mauricio Fernández <mfp@acm.org> *)
open Printf
open Mq_types
open Lwt

module PGOCaml = PGOCaml_lwt
INCLUDE "mq_schema.ml"

type t = {
  dbconns : PGOCaml.pa_pg_data PGOCaml.t Lwt_pool.t;
  dbconns' : PGOCaml.pa_pg_data PGOCaml.t Lwt_pool.t; (* low priority *)
  debug : bool
}

let initialize t = Lwt_pool.use t.dbconns create_db

let connect
      ?host ?port ?unix_domain_socket_dir ?database ?user ?password
      ?(debug = false) ?(max_conns = 2) () =
  let create_conn () = PGOCaml.connect ?host ?port ?database ?unix_domain_socket_dir
                         ?user ?password () in
  let max_conns = max 2 max_conns in
  let pool = Lwt_pool.create (max_conns / 2) create_conn in
  let pool' = Lwt_pool.create (max_conns / 2) create_conn in
    (* try to connect so we raise the exception as early as possible if
     * something's wrong *)
  Lwt_pool.use pool (fun _ -> return ()) >>
  return { dbconns = pool; dbconns' = pool'; debug = debug }

let msg_of_tuple (msg_id, dst, timestamp, priority, ack_timeout, body) =
  {
    msg_id = msg_id;
    msg_destination = Queue dst;
    msg_priority = Int32.to_int priority;
    msg_timestamp = CalendarLib.Calendar.to_unixfloat timestamp;
    msg_ack_timeout = ack_timeout;
    msg_body = body;
  }

DEFINE WithDB(x) = Lwt_pool.use t.dbconns (fun dbh -> x)
DEFINE WithDB_trans(x) =
  Lwt_pool.use t.dbconns
    (fun dbh ->
       PGOCaml.begin_work dbh >>
       try_lwt
         lwt y = x in
         PGOCaml.commit dbh >> return y
       with e -> PGOCaml.rollback dbh >> fail e)

let do_save t dbh ?(ack_pending = false) msg =
  let body = msg.msg_body in
  let time = CalendarLib.Calendar.from_unixfloat msg.msg_timestamp in
  let msg_id = msg.msg_id in
  let priority = Int32.of_int msg.msg_priority in
  let queue = destination_name msg.msg_destination in
  let ack_timeout = msg.msg_ack_timeout in
    if t.debug then eprintf "Saving message %S.\n%!" msg_id;
    PGSQL(dbh)
     "INSERT INTO ocamlmq_msgs(msg_id, ack_pending, priority, destination,
                               timestamp, ack_timeout, body)
             VALUES ($msg_id, $ack_pending, $priority, $queue, $time,
                     $ack_timeout, $body)"

let save_msg t ?(low_priority = false) msg = match msg.msg_destination with
    Topic _ | Control _ -> return ()
  | Queue queue ->
      if not low_priority then WithDB(do_save t dbh msg)
      else Lwt_pool.use t.dbconns' (fun dbh -> do_save t dbh msg)

let get_ack_pending_msg t msg_id =
  WithDB begin
    PGSQL(dbh)
       "SELECT msg_id, destination, timestamp, priority, ack_timeout, body
          FROM ocamlmq_msgs as msg
         WHERE msg_id = $msg_id AND ack_pending = true"
  end
  >>= function
    | tuple :: _ -> return (Some (msg_of_tuple tuple))
    | [] -> return None

let register_ack_pending_new_msg t msg =
  WithDB(do_save t dbh ~ack_pending:true msg)

let register_ack_pending_msg t msg_id =
  try_lwt
    WithDB_trans begin
      PGSQL(dbh)
        "SELECT 1 FROM ocamlmq_msgs
          WHERE msg_id = $msg_id AND ack_pending = false
          FOR UPDATE" >>= function
        [] -> return false
      | _ ->
          PGSQL(dbh)
            "UPDATE ocamlmq_msgs SET ack_pending = true WHERE msg_id = $msg_id" >>
          return true
    end
  with _ -> return false

let rec get_msg_for_delivery t queue =
  try_lwt
    WithDB_trans begin
      lwt tuples =
        PGSQL(dbh)
          "SELECT msg_id, destination, timestamp, priority, ack_timeout, body
             FROM ocamlmq_msgs as msg
            WHERE destination = $queue AND ack_pending = false
         ORDER BY priority, timestamp
            LIMIT 1
       FOR UPDATE"
      in match tuples with
          tuple :: _ ->
            let msg = msg_of_tuple tuple in
            let msg_id = msg.msg_id in
              PGSQL(dbh)
                "UPDATE ocamlmq_msgs SET ack_pending = true
                  WHERE msg_id = $msg_id" >>
              return (Some msg)
        | [] -> return None
    end
  with _ -> return None (* FIXME: is this OK? *)

let ack_msg t msg_id =
  WithDB(PGSQL(dbh) "DELETE FROM ocamlmq_msgs WHERE msg_id = $msg_id")

let unack_msg t msg_id =
  WithDB(PGSQL(dbh) "UPDATE ocamlmq_msgs SET ack_pending = false WHERE msg_id = $msg_id")

let count_queue_msgs t queue =
  WithDB(PGSQL(dbh) "SELECT COUNT(*) FROM ocamlmq_msgs WHERE destination = $queue")
    >>= function
        Some count :: _ -> return count
      | _ -> return 0L

let crash_recovery t =
  WithDB_trans begin
    if t.debug then eprintf "Recovering from crash...\n%!";
    PGSQL(dbh) "SELECT COUNT(*) FROM ocamlmq_msgs WHERE ack_pending = true" >>= function
        Some n :: _ ->
          eprintf "Recovering %Ld ACK-pending messages: %!" n;
          lwt () = PGSQL(dbh) "UPDATE ocamlmq_msgs SET ack_pending = false
                                WHERE ack_pending = true" in
          eprintf "DONE\n%!";
          return ()
      | _ -> eprintf "No ACK-pending messages found.\n%!";
             return ()
  end
