// Bots through the real engine (Registry + canister_players +
// ConnectFourRules), as the host wires them: a canister takes the open
// seat the way a bot's `play` makes it (`join_table_as_canister`), is asked
// for each drop it is due with its own seat's view, and has its reply
// applied as the move. The canister here is a stand-in that always drops
// into the leftmost open column; the rejection text of an illegal reply
// comes back to it on the one retry; a Rematch holds the seat for the same
// bot; and once the human returns to the lobby the bot leaves too, so it
// never piles up tables.
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Time "mo:core/Time";

import TP "mo:duel-game-core";
import CanisterPlayers "mo:duel-game-core/canister_players";
import Registry "mo:duel-game-core/registry";
import Rng "mo:duel-game-core/rng";

import Rules "../src/ConnectFourRules";

let rng = Rng.new(5);
let spec = Rules.spec;

func ok<T>(r : TP.Res<T>, msg : Text) : T = switch (r) {
  case (#ok v) v;
  case (#err e) Runtime.trap(msg # " unexpectedly failed: " # debug_show (e));
};

let reg = Registry.new<Rules.State, Rules.Action, Rules.Options>();
reg.setTimeouts(150_000_000_000, 120_000_000_000);

let bot = Principal.fromText("2vxsx-fae");
let botId = CanisterPlayers.idForCanister(bot, "Leftmost");
let human = "alice";

var asks = 0;
var illegalFirst = false; // the next ask is answered with column 7 first
var retried = false;
let ctx : CanisterPlayers.Ctx<Rules.State, Rules.Action, Rules.View, Rules.Options> = {
  registry = reg;
  spec;
  rng;
  store = CanisterPlayers.newStore();
  call = func<system>(player : TP.PlayerId, req : TP.MoveRequest<Rules.View, Rules.Action>, k : <system>(?Rules.Action) -> async* ()) : async* () {
    asks += 1;
    assert player == botId;
    assert req.seat == #p2 and req.complexity == "Leftmost" and req.opponent == human;
    assert Rules.toMove(req.game) == #p2; // asked only when on turn
    if (illegalFirst and req.retryReason == null) {
      await* k<system>(?#drop { col = 7 });
      return;
    };
    if (req.retryReason != null) {
      assert req.retryReason == ?"There is no such column.";
      retried := true;
      illegalFirst := false;
    };
    await* k<system>(?Rules.legalActions(req.game, req.seat)[0]);
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

// Alice drops into column 3 until she has four there; the bot, always in
// the leftmost open column, never stops her.
func playToRedWin(id : TP.TableId) : async* () {
  for (_ in [0, 1, 2, 3].values()) {
    switch (viewOf(human, id)) {
      case (#inGame v) {
        assert not v.youSubmitted; // the bot has already answered
        switch (ok(reg.submit(spec, rng, Time.now(), human, id, v.gen, v.step, #drop { col = 3 }), "alice drops")) {
          case (#gameEnded { verdict }) {
            assert verdict == #p1Wins;
            return;
          };
          case (_) await* ctx.afterMutation<system>(Time.now(), id, true);
        };
      };
      case (other) Runtime.trap("alice should be in a game, got " # debug_show other);
    };
  };
  Runtime.trap("four in column 3 should have won");
};

// ── 1. the bot takes the open seat and answers every drop at once ─────────
let id = ok(reg.createTable(spec, rng, Time.now(), human, #p1, #open, {}), "alice opens a table as Red");
switch (ok(await* cp.joinTable<system>(bot, id, #p2, null, "Leftmost"), "the bot takes Yellow")) {
  case (#started _) {};
  case (other) Runtime.trap("the bot's join should start the game, got " # debug_show other);
};
await* playToRedWin(id);
assert asks == 3; // one ask per Yellow drop between Red's four
for (p in [human, botId].values()) {
  switch (viewOf(p, id)) {
    case (#debrief d) {
      assert d.end == #finished(#p1Wins);
      assert d.finalGame.board[0] == ?#p2; // the bot's discs: leftmost column
      assert d.finalGame.winLine == [3, 10, 17, 24];
    };
    case (other) Runtime.trap(p # " should see Red's win, got " # debug_show other);
  };
};
Debug.print("1. a bot seat is asked for each drop with its own view, and the game finishes OK");

// ── 2. Rematch: the seat is held for the same bot, which re-joins ──────────
switch (ok(reg.rematch(spec, rng, Time.now(), human, id), "alice asks for a rematch")) {
  case (#awaitingPartner) {};
  case (other) Runtime.trap("a rematch against a bot should stage, got " # debug_show other);
};
switch (viewOf(human, id)) {
  case (#stagingYou s) assert s.reservedForPartner;
  case (other) Runtime.trap("alice should wait for the bot, got " # debug_show other);
};
// Someone else cannot take the bot's seat meanwhile.
switch (await* cp.joinTable<system>(Principal.fromText("aaaaa-aa"), id, #p2, null, "")) {
  case (#err(#reserved _)) {};
  case (other) Runtime.trap("another canister must not take the held seat, got " # debug_show other);
};
// The frontend re-issues the same `play`: same bot, same level.
illegalFirst := true;
switch (ok(await* cp.joinTable<system>(bot, id, #p2, null, "Leftmost"), "the bot re-joins")) {
  case (#started _) {};
  case (other) Runtime.trap("the bot's re-join should start the rematch, got " # debug_show other);
};
Debug.print("2. a Rematch holds the seat for the same bot, nobody else can take it, and the bot re-joins OK");

// ── 3. an illegal reply is retried once with the rules' reason ─────────────
await* playToRedWin(id);
assert retried;
Debug.print("3. an illegal drop is refused and asked again with the rules' reason OK");

// ── 4. once alice leaves the debrief, the bot leaves the table too ─────────
assert reg.tablesOf(botId).size() == 1;
let gen = switch (viewOf(human, id)) {
  case (#debrief d) d.gen;
  case (other) Runtime.trap("alice should see the rematch's debrief, got " # debug_show other);
};
ignore ok(reg.leave(Time.now(), human, id, gen), "alice returns to the lobby");
await* ctx.afterMutation<system>(Time.now(), id, true);
assert reg.tablesOf(botId).size() == 0;
assert reg.tablesOf(human).size() == 0;
Debug.print("4. the bot acks its debrief after the human, holding no table OK");

Debug.print("ALL ConnectFour CANISTER PLAYER CHECKS PASSED");
