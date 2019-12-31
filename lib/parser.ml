type 'a state =
  | Partial of 'a partial
  | Jump    of (unit -> 'a state)
  | Done    of int * 'a
  | Fail    of int * string list * string
and 'a partial =
  { committed : int
  ; continue  : Bigstringaf.t -> off:int -> len:int -> More.t -> 'a state }

type 'a with_state = Input.t ->  int -> More.t -> 'a

type 'a failure = (string list -> string -> 'a state) with_state
type ('a, 'r) success = ('a -> 'r state) with_state

type 'a t =
  { run : 'r. ('r failure -> ('a, 'r) success -> 'r state) with_state }

let fail_k    input pos _ marks msg = Fail(pos - Input.client_committed_bytes input, marks, msg)
let succeed_k input pos _       v   = Done(pos - Input.client_committed_bytes input, v)

let fail_to_string marks err =
  String.concat " > " marks ^ ": " ^ err

let state_to_option = function
  | Done(_, v) -> Some v
  | _          -> None

let rec state_to_result = function
  | Done(_, v)          -> Ok v
  | Partial _           -> Error "incomplete input"
  | Jump jump           -> (state_to_result[@tailcall]) (jump ())
  | Fail(_, marks, err) -> Error (fail_to_string marks err)

let parse p =
  let input = Input.create Bigstringaf.empty ~committed_bytes:0 ~off:0 ~len:0 in
  p.run input 0 Incomplete fail_k succeed_k

let parse_bigstring p input =
  let input = Input.create input ~committed_bytes:0 ~off:0 ~len:(Bigstringaf.length input) in
  state_to_result (p.run input 0 Complete fail_k succeed_k)

module Monad = struct
  let return v =
    { run = fun input pos more _fail succ ->
          succ input pos more v
    }

  let fail msg =
    { run = fun input pos more fail _succ ->
          fail input pos more [] msg
    }

  let (>>=) p f =
    { run = fun input pos more fail succ ->
          let succ' input' pos' more' v = Jump (fun () -> (f v).run input' pos' more' fail succ) in
          p.run input pos more fail succ'
    }

  let (>>|) p f =
    { run = fun input pos more fail succ ->
          let succ' input' pos' more' v = Jump (fun () -> succ input' pos' more' (f v)) in
          p.run input pos more fail succ'
    }

  let (<$>) f m =
    m >>| f

  let (<*>) f m =
    (* f >>= fun f -> m >>| f *)
    { run = fun input pos more fail succ ->
          let succ0 input0 pos0 more0 f =
            let succ1 input1 pos1 more1 m = Jump (fun () -> succ input1 pos1 more1 (f m)) in
            Jump (fun () -> m.run input0 pos0 more0 fail succ1)
          in
          f.run input pos more fail succ0 }

  let lift f m =
    f <$> m

  let lift2 f m1 m2 =
    { run = fun input pos more fail succ ->
          let succ1 input1 pos1 more1 m1 =
            let succ2 input2 pos2 more2 m2 = Jump (fun () -> succ input2 pos2 more2 (f m1 m2)) in
            Jump (fun () -> m2.run input1 pos1 more1 fail succ2)
          in
          m1.run input pos more fail succ1 }

  let lift3 f m1 m2 m3 =
    { run = fun input pos more fail succ ->
          let succ1 input1 pos1 more1 m1 =
            let succ2 input2 pos2 more2 m2 =
              let succ3 input3 pos3 more3 m3 =
                Jump (fun () -> succ input3 pos3 more3 (f m1 m2 m3)) in
              Jump (fun () -> m3.run input2 pos2 more2 fail succ3) in
            Jump (fun () -> m2.run input1 pos1 more1 fail succ2)
          in
          Jump (fun () -> m1.run input pos more fail succ1) }

  let lift4 f m1 m2 m3 m4 =
    { run = fun input pos more fail succ ->
          let succ1 input1 pos1 more1 m1 =
            let succ2 input2 pos2 more2 m2 =
              let succ3 input3 pos3 more3 m3 =
                let succ4 input4 pos4 more4 m4 =
                  Jump (fun () -> succ input4 pos4 more4 (f m1 m2 m3 m4)) in
                Jump (fun () -> m4.run input3 pos3 more3 fail succ4) in
              Jump (fun () -> m3.run input2 pos2 more2 fail succ3) in
            Jump (fun () -> m2.run input1 pos1 more1 fail succ2)
          in
          Jump (fun () -> m1.run input pos more fail succ1) }

  let ( *>) a b =
    (* a >>= fun _ -> b *)
    { run = fun input pos more fail succ ->
          let succ' input' pos' more' _ = Jump (fun () -> b.run input' pos' more' fail succ) in
          Jump (fun () -> a.run input pos more fail succ')
    }

  let (<* ) a b =
    (* a >>= fun x -> b >>| fun _ -> x *)
    { run = fun input pos more fail succ ->
          let succ0 input0 pos0 more0 x =
            let succ1 input1 pos1 more1 _ = Jump (fun () -> succ input1 pos1 more1 x) in
            Jump (fun () -> b.run input0 pos0 more0 fail succ1)
          in
          a.run input pos more fail succ0 }
end

module Choice = struct
  let (<?>) p mark =
    { run = fun input pos more fail succ ->
          let fail' input' pos' more' marks msg =
            fail input' pos' more' (mark::marks) msg in
          Jump (fun () -> p.run input pos more fail' succ)
    }

  let (<|>) p q =
    { run = fun input pos more fail succ ->
          let fail' input' pos' more' marks msg =
            (* The only two constructors that introduce new failure continuations are
             * [<?>] and [<|>]. If the initial input position is less than the length
             * of the committed input, then calling the failure continuation will
             * have the effect of unwinding all choices and collecting marks along
             * the way. *)
            if pos < Input.parser_committed_bytes input' then
              fail input' pos' more marks msg
            else
              Jump (fun () -> q.run input' pos more' fail succ) in
          p.run input pos more fail' succ
    }
end

module Monad_use_for_debugging = struct
  let return = Monad.return
  let fail   = Monad.fail
  let (>>=)  = Monad.(>>=)

  let (>>|) m f = m >>= fun x -> return (f x)

  let (<$>) f m = m >>| f
  let (<*>) f m = f >>= fun f -> m >>| f

  let lift  = (>>|)
  let lift2 f m1 m2       = f <$> m1 <*> m2
  let lift3 f m1 m2 m3    = f <$> m1 <*> m2 <*> m3
  let lift4 f m1 m2 m3 m4 = f <$> m1 <*> m2 <*> m3 <*> m4

  let ( *>) a b = a >>= fun _ -> b
  let (<* ) a b = a >>= fun x -> b >>| fun _ -> x
end
