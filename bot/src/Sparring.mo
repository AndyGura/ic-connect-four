import InternetComputer "mo:core/InternetComputer";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Time "mo:core/Time";

import TP "mo:duel-game-core";
import Transport "mo:duel-game-core/transport";

import BotLogic "BotLogic";
import Game "GameTypes";

// Local tests only: takes the bot's opponent seat as a human would, one
// request per call. The table it plays at is the one it opened last.
actor Sparring {

  type Reply = Transport.Reply<Game.View>;
  type Host = actor {
    duel_create_table : (TP.Seat, TP.TableVisibility, Game.Options) -> async Transport.Ack;
    duel_ack_ended : (TP.TableId) -> async Transport.Ack;
    duel_submit : (TP.TableId, Nat, Nat, Game.Action) -> async Reply;
    duel_table : query (TP.TableId, Nat) -> async Transport.TableResult<Game.View>;
  };

  var tableId : TP.TableId = 0;

  func hostOf(host : Principal.Principal) : Host = actor (host.toText());

  // The table's current view (`rev = 0` always answers).
  func view(host : Principal.Principal) : async Reply {
    switch (await hostOf(host).duel_table(tableId, 0)) {
      case (#changed v) #view v;
      case _ #err(#noSuchTable);
    };
  };

  // Answers the new table's id (and rev), which `bot play` needs next.
  public func open_table(host : Principal.Principal, seat : TP.Seat, options : Game.Options) : async Transport.Ack {
    let ack = await hostOf(host).duel_create_table(seat, #open, options);
    switch ack {
      case (#ok { tableId = id }) tableId := id;
      case (#err _) {};
    };
    ack;
  };

  // One move when this seat is due; the fresh view either way.
  public func step(host : Principal.Principal, complexity : Text) : async Reply {
    let current = await view(host);
    switch current {
      case (#view { view = #inGame g }) {
        if (g.youSubmitted) return current;
        let move = BotLogic.chooseMove(
          {
            tableId;
            seat = g.seat;
            game = g.game;
            mode = g.mode;
            step = g.step;
            gen = g.gen;
            complexity;
            retryReason = null;
            opponent = "";
            opponentLastMove = null;
            lastStepDurationNs = null;
          },
          Nat64.fromIntWrap(Time.now()),
          func() = InternetComputer.performanceCounter(0) > 1_200_000_000,
        );
        await hostOf(host).duel_submit(tableId, g.gen, g.step, move);
      };
      case _ current;
    };
  };

  public func ack_ended(host : Principal.Principal) : async Transport.Ack {
    await hostOf(host).duel_ack_ended(tableId);
  };

};
