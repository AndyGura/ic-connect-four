// Whole games of the bot through the game's real engine and rules. This
// repository's src/ConnectFourRules.mo, with duel-core at the commit in
// README.md, builds byte for byte into the live module
// (c9ed010f…da2c), so the engine here (Registry + canister_players +
// those rules, as the Host wires them) is the live game's own code, run in
// the interpreter instead of a replica. A "sparring" player takes the
// other seat; the bot is asked for every drop it is due and its reply is
// applied as the move. Every complexity, the bot in each seat, against
// every complexity as sparring: each game must reach its real ending
// with the bot answering every ask, legally, at the first try.
//
// Hard runs with a small node budget here (the interpreter is slow);
// tools/arena.mo plays it at full strength.
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Time "mo:core/Time";

import TP "mo:duel-game-core";
import CanisterPlayers "mo:duel-game-core/canister_players";
import Registry "mo:duel-game-core/registry";
import Rng "mo:duel-game-core/rng";

import Rules "../../src/ConnectFourRules";

import BotLogic "../src/BotLogic";
import GameRules "../src/GameRules";
import Search "../src/Search";

let rng = Rng.new(11);
let spec = Rules.spec;
let never = func() : Bool = false;
let HARD_TEST : Search.Settings = { BotLogic.HARD with maxNodes = 1_500; ttSize = 4093 };

func settings(complexity : Text) : ?Search.Settings = if (complexity == "Hard") ?HARD_TEST else BotLogic.settingsFor(complexity);

func ok<T>(r : TP.Res<T>, msg : Text) : T = switch (r) {
  case (#ok v) v;
  case (#err e) Runtime.trap(msg # " unexpectedly failed: " # debug_show (e));
};

let reg = Registry.new<Rules.State, Rules.Action, Rules.Options>();
reg.setTimeouts(150_000_000_000, 120_000_000_000);

let bot = Principal.fromText("2vxsx-fae");
let sparring = "sparring";

var botLevel = "";
var botSeat : TP.Seat = #p2;
var asks = 0;
var game = 0;

let ctx : CanisterPlayers.Ctx<Rules.State, Rules.Action, Rules.View, Rules.Options> = {
  registry = reg;
  spec;
  rng;
  store = CanisterPlayers.newStore();
  // The live Host's `callBot`, with `make_move` answered in-process.
  call = func<system>(player : TP.PlayerId, req : TP.MoveRequest<Rules.View, Rules.Action>, k : <system>(?Rules.Action) -> async* ()) : async* () {
    asks += 1;
    assert player == CanisterPlayers.idForCanister(bot, botLevel);
    assert req.complexity == botLevel and req.seat == botSeat and req.opponent == sparring;
    assert GameRules.toMove(req.game.board) == botSeat; // asked only when on turn
    if (req.retryReason != null) Runtime.trap("the bot's reply was rejected: " # debug_show req.retryReason);
    let move = BotLogic.chooseWith(req, settings(botLevel), Nat64.fromNat(game * 1000 + req.step), never);
    assert GameRules.validate(req.game.board, move) == null;
    await* k<system>(?move);
  };
  afterMutation = func<system>(now : Int, id : TP.TableId, _ : Bool) : async* () {
    await* CanisterPlayers.settle<system, Rules.State, Rules.Action, Rules.View, Rules.Options>(ctx, now, id);
  };
  arm = func<system>(_ : TP.TableId, _ : Nat) {};
};
let cp = CanisterPlayers.endpointOf(ctx);

func viewOf(player : TP.PlayerId, id : TP.TableId) : TP.TableView<Rules.View> = switch (reg.view(spec, Time.now(), player, id)) {
  case (?v) v;
  case null Runtime.trap("no table " # id.toText());
};

// One game: sparring opens the table in the other seat, the bot joins,
// sparring moves whenever it is due. Answers the verdict.
func playGame(level : Text, seat : TP.Seat, sparringLevel : Text) : async* TP.Verdict {
  botLevel := level;
  botSeat := seat;
  asks := 0;
  game += 1;
  let id = ok(reg.createTable(spec, rng, Time.now(), sparring, (if (seat == #p1) #p2 else #p1), #open, {}), "sparring opens a table");
  ignore ok(await* cp.joinTable<system>(bot, id, seat, null, level), "the bot joins");
  var sparringMoves = 0;
  var botMoves = 0;
  loop {
    switch (viewOf(sparring, id)) {
      case (#inGame v) {
        // The bot always answered inside the previous call: sparring is due.
        assert not v.youSubmitted;
        let move = BotLogic.chooseWith(
          {
            tableId = id;
            seat = v.seat;
            game = v.game;
            mode = v.mode;
            step = v.step;
            gen = v.gen;
            complexity = sparringLevel;
            retryReason = null;
            opponent = "";
            opponentLastMove = null;
            lastStepDurationNs = null;
          },
          settings(sparringLevel),
          Nat64.fromNat(game * 7919 + v.step),
          never,
        );
        sparringMoves += 1;
        switch (ok(reg.submit(spec, rng, Time.now(), sparring, id, v.gen, v.step, move), "sparring drops")) {
          case (#gameEnded _) {};
          case (_) await* ctx.afterMutation<system>(Time.now(), id, true);
        };
      };
      case (#debrief d) {
        botMoves := asks;
        let board = d.finalGame.board;
        let discs = GameRules.discs(board);
        assert d.steps == discs and discs == sparringMoves + botMoves;
        assert botMoves == (if (seat == #p1) (discs + 1) / 2 else discs / 2);
        let verdict = switch (d.end) {
          case (#finished v) v;
          case (other) Runtime.trap("the game did not reach its real ending: " # debug_show other);
        };
        switch (verdict) {
          case (#p1Wins) assert GameRules.hasFour(board, #p1) and d.finalGame.winLine.size() >= 4;
          case (#p2Wins) assert GameRules.hasFour(board, #p2) and d.finalGame.winLine.size() >= 4;
          case (#draw) assert discs == 42 and not GameRules.hasFour(board, #p1) and not GameRules.hasFour(board, #p2);
        };
        ignore ok(reg.leave(Time.now(), sparring, id, d.gen), "sparring returns to the lobby");
        await* ctx.afterMutation<system>(Time.now(), id, true);
        assert reg.tablesOf(CanisterPlayers.idForCanister(bot, level)).size() == 0;
        Debug.print(
          "  bot " # level # " as " # debug_show seat # " vs sparring " # sparringLevel # ": " # debug_show verdict # " in " # discs.toText() # " drops, the bot answered " # botMoves.toText() # " asks"
        );
        return verdict;
      };
      case (other) Runtime.trap("sparring should be in the game, got " # debug_show other);
    };
  };
};

func botWon(seat : TP.Seat, v : TP.Verdict) : Bool = (seat == #p1 and v == #p1Wins) or (seat == #p2 and v == #p2Wins);

for (level in BotLogic.COMPLEXITIES.values()) {
  for (seat in [#p1, #p2].values()) {
    for (sparringLevel in BotLogic.COMPLEXITIES.values()) {
      let v = await* playGame(level, seat, sparringLevel);
      // Even shallow, Hard beats Easy from either seat.
      if (level == "Hard" and sparringLevel == "Easy") assert botWon(seat, v);
    };
  };
};
Debug.print("ALL WHOLE GAMES REACHED THEIR ENDING, THE BOT ANSWERING EVERY ASK");
