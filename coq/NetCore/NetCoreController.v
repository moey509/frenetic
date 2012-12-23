Set Implicit Arguments.

Require Import Common.Types.
Require Import Common.Monad.
Require Import Word.WordInterface.
Require Import Network.Packet.
Require Import OpenFlow.MessagesDef.
Require Import Pattern.Defs.
Require Import Classifier.Defs.
Require Import NetCore.NetCore.
Require Import OpenFlow.ControllerInterface.

Local Open Scope list_scope.

Section Prioritize.

  (** TODO(arjun): deal with priority overflowing 16 bits *)
  Fixpoint prio_rec {A : Type} (prio : Word16.t) (lst : Classifier A) :=
    match lst with
      | nil => nil
      | (pat, act) :: rest => 
        (prio, pat, act) :: (prio_rec (Word16.pred prio) rest)
    end.

  Definition prioritize {A : Type} (lst : Classifier A) :=
    prio_rec Word16.max_value lst.

End Prioritize.

Section ToFlowMod.

  Definition translate_action (act : Action) :=
    match act with
      | Forward pp => Output pp
      | ActGetPkt x => Output (Controller Word16.max_value)
    end.

  Definition to_flow_mod prio (pat : Pattern) (act : list Action)
             (isfls : Pattern.is_empty pat = false) :=
    FlowMod AddFlow
            (Pattern.to_match pat isfls)
            prio
            (List.map translate_action act)
            Word64.zero
            Permanent
            Permanent
            false
            None
            None
            false.

  Definition flow_mods_of_classifier lst :=
    List.fold_right
      (fun (ppa : priority * Pattern * list Action)
           (lst : list flowMod) => 
         match ppa with
           | (prio,pat,act) => 
             (match (Pattern.is_empty pat) as b
                    return (Pattern.is_empty pat = b -> list flowMod) with
                | true => fun _ => lst
                | false => fun H => (to_flow_mod prio pat act H) :: lst
              end) eq_refl
         end)
      nil
      (prioritize lst).

  Lemma Pattern_all_not_empty : Pattern.is_empty Pattern.all = false.
  Proof.
    unfold Pattern.is_empty.
    reflexivity.
  Qed.

  Definition delete_all_flows := 
    FlowMod DeleteFlow
            (* This should make reasoning easier, since we have so many
               theorems about patterns. *)
            (Pattern.to_match Pattern.all Pattern_all_not_empty)
            Word16.zero
            nil
            Word64.zero
            Permanent
            Permanent
            false
            None
            None
            false.


End ToFlowMod.

Record ncstate := State {
  policy : Pol;
  switches : list switchId
}.

Module Type NETCORE_MONAD <: CONTROLLER_MONAD.

  Include MONAD.


  Definition state := ncstate.

  Parameter get : m state.
  Parameter put : state -> m unit.
  Parameter send : switchId -> xid -> message -> m unit.
  Parameter recv : m event.

  (** Must be defined in OCaml *)
  Parameter forever : m unit -> m unit.

End NETCORE_MONAD.

Module Make (Import Monad : NETCORE_MONAD).

  Local Notation "x <- M ; K" := (bind M (fun x => K)).

  Fixpoint sequence (lst : list (m unit)) : m unit := 
    match lst with
      | nil => ret tt
      | cmd :: lst' =>
        bind cmd (fun _ => sequence lst')
    end.
  
  Definition config_commands (pol: Pol) (swId : switchId) :=
    sequence
      (List.map
         (fun fm => send swId Word32.zero (FlowModMsg fm))
         (delete_all_flows 
            :: (flow_mods_of_classifier (compile_opt pol swId)))).

  Definition set_policy (pol : Pol) := 
    st <- get;
    let switch_list := switches st in
    _ <- put (State pol switch_list);
    _ <- sequence (List.map (config_commands pol) switch_list);
    ret tt.

  Definition handle_switch_disconnected (swId : switchId) :=
    st <- get;
    let switch_list := 
        List.filter 
          (fun swId' => match Word64.eq_dec swId swId' with
                          | left _ => false
                          | right  _ => true
                        end)
          (switches st) in
    _ <- put (State (policy st) switch_list);
    ret tt.

  (** TODO(arjun): I'm assuming we don't disconnected and connected are
      interleaved. OCaml should provide that guarantee. *)
  Definition handle_switch_connected (swId : switchId) :=
    st <- get;
    _ <- put (State (policy st) (swId :: (switches st)));
    _ <- config_commands (policy st) swId;
    ret tt.

  Definition body :=
    evt <- recv;
    match evt with
      | SwitchDisconnected swId => handle_switch_disconnected swId
      | SwitchConnected swId => handle_switch_connected swId
      | SwitchMessage swId xid msg => ret tt
    end.

  Definition main := forever body.

End Make.