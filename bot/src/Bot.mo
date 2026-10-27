import InternetComputer "mo:core/InternetComputer";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Time "mo:core/Time";

import TP "mo:duel-game-core";

import BotLogic "BotLogic";
import Game "GameTypes";

actor {

  type Host = actor {
    join_table_as_canister : (TP.TableId, TP.Seat, ?Text, Text) -> async TP.Res<TP.JoinOk>;
    register_bot : (Text, [Text]) -> async ();
    unregister_bot : () -> async ();
  };

  // Called by frontends to challenge this bot.
  public shared func play(host : Principal.Principal, tableId : TP.TableId, seat : TP.Seat, code : ?Text, complexity : Text) : async TP.Res<TP.JoinOk> {
    let h : Host = actor (host.toText());
    await h.join_table_as_canister(tableId, seat, code, complexity);
  };

  public shared ({ caller }) func register(host : Principal.Principal, name : Text) : async () {
    assert caller.isController();
    let h : Host = actor (host.toText());
    await h.register_bot(name, BotLogic.COMPLEXITIES);
  };

  public shared ({ caller }) func unregister(host : Principal.Principal) : async () {
    assert caller.isController();
    let h : Host = actor (host.toText());
    await h.unregister_bot();
  };

  // The instructions this message has executed so far: Hard's budget.
  func clock() : Nat = InternetComputer.performanceCounter(0).toNat();

  public query func make_move(req : TP.MoveRequest<Game.View, Game.Action>) : async Game.Action {
    BotLogic.chooseMove(req, Nat64.fromIntWrap(Time.now()), clock);
  };

  /// What Hard (or `complexity`) would play here and how deep it saw:
  /// for checking the search's depth and cost on a live canister.
  public query func analyse(board : [?Game.Seat], seat : Game.Seat, complexity : Text) : async {
    col : Nat;
    score : Int64;
    depth : Nat;
    nodes : Nat;
    exact : ?Int;
    instructions : Nat64;
  } {
    let settings = switch (BotLogic.settingsFor(complexity)) {
      case (?s) s;
      case null BotLogic.HARD;
    };
    let r = BotLogic.searchCol(board, seat, settings, Nat64.fromIntWrap(Time.now()), clock);
    { r with instructions = InternetComputer.performanceCounter(0) };
  };

};
