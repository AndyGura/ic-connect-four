// Whole games through the real engine (Table + ConnectFourRules), no
// seeding needed: a game is at most 42 actions. Red wins one, a rematch
// is drawn on a full board, and the engine's own gates (turn order, the
// rules' rejections, a stale step) hold in between.
import TP "mo:duel-game-core";
import Rng "mo:duel-game-core/rng";
import Table "mo:duel-game-core/table";
import Rules "../src/ConnectFourRules";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";

let rng = Rng.new(7);
let spec = Rules.spec;
let now : Int = 1_000_000_000_000;

func ok<T>(r : TP.Res<T>, msg : Text) : T = switch (r) {
  case (#ok v) v;
  case (#err e) Runtime.trap(msg # " unexpectedly failed: " # debug_show (e));
};

let t = Table.new<Rules.State, Rules.Action, Rules.Options>(150_000_000_000, 120_000_000_000, #open, "red", {});

func inGame(session : Text) : { gen : Nat; step : Nat; game : Rules.View; youSubmitted : Bool } = switch (t.status(spec, now, session)) {
  case (#inGame v) v;
  case (_) Runtime.trap(session # " is not in a live game");
};

func drop(session : Text, col : Nat) : TP.SubmitOk {
  let v = inGame(session);
  ok(t.submit(spec, rng, now, session, v.gen, v.step, #drop { col }), session # " drops into " # debug_show col);
};

// ── 1. seating: Red and Yellow, Red on turn ────────────────────────────────
ignore ok(t.join(spec, rng, now, "red", #p1), "red joins");
switch (ok(t.join(spec, rng, now, "yellow", #p2), "yellow joins")) {
  case (#started _) {};
  case (_) Runtime.trap("the second seat should start the game");
};
assert not inGame("red").youSubmitted;
assert inGame("yellow").youSubmitted; // turn-based: not on turn
Debug.print("1. join OK");

// ── 2. the engine's gates and the rules' rejections ────────────────────────
do {
  let y = inGame("yellow");
  switch (t.submit(spec, rng, now, "yellow", y.gen, y.step, #drop { col = 3 })) {
    case (#err(#notYourTurn)) {};
    case (_) Runtime.trap("yellow must wait for red");
  };
  let r = inGame("red");
  switch (t.submit(spec, rng, now, "red", r.gen, r.step, #drop { col = 7 })) {
    case (#err(#illegalMove "There is no such column.")) {};
    case (_) Runtime.trap("column 7 must be refused by the rules");
  };
  switch (t.submit(spec, rng, now, "red", r.gen, r.step + 1, #drop { col = 3 })) {
    case (#err(#stale)) {};
    case (_) Runtime.trap("a wrong step must be stale");
  };
};
Debug.print("2. turn order, rule rejections, stale step OK");

// ── 3. a full column is refused through the engine ─────────────────────────
for (k in [0, 1, 2, 3, 4, 5].values()) {
  ignore drop(if (k % 2 == 0) "red" else "yellow", 3);
};
do {
  let r = inGame("red");
  assert r.step == 6;
  switch (t.submit(spec, rng, now, "red", r.gen, r.step, #drop { col = 3 })) {
    case (#err(#illegalMove "That column is full.")) {};
    case (_) Runtime.trap("a seventh disc in column 3 must be refused");
  };
};
Debug.print("3. full column refused OK");

// ── 4. Red stacks four in column 0 and wins ────────────────────────────────
ignore drop("red", 0);
ignore drop("yellow", 1);
ignore drop("red", 0);
ignore drop("yellow", 1);
ignore drop("red", 0);
ignore drop("yellow", 1);
switch (drop("red", 0)) {
  case (#gameEnded { verdict = #p1Wins; steps = 13 }) {};
  case (_) Runtime.trap("red's fourth disc in column 0 must win after 13 drops");
};
for (session in ["red", "yellow"].values()) {
  switch (t.status(spec, now, session)) {
    case (#debrief d) {
      assert d.end == #finished(#p1Wins);
      assert d.finalGame.winLine == [0, 7, 14, 21];
      assert d.finalGame.lastMove == ?{ col = 0; row = 3; seat = #p1 };
    };
    case (_) Runtime.trap(session # " should see the debrief");
  };
};
Debug.print("4. a vertical win ends the game for both seats OK");

// ── 5. rematch: a fresh board, then a 42-disc draw ─────────────────────────
ignore ok(t.rematch(spec, rng, now, "red"), "red asks for a rematch");
switch (ok(t.rematch(spec, rng, now, "yellow"), "yellow accepts")) {
  case (#started) {};
  case (_) Runtime.trap("both rematches should start a new game");
};
assert inGame("red").game == Rules.init({}, rng);

// A gravity- and turn-respecting order that fills the board without a line.
let fill : [Nat] = [4, 3, 4, 3, 3, 3, 3, 2, 3, 2, 2, 2, 2, 2, 1, 4, 4, 4, 4, 6, 1, 1, 1, 1, 5, 1, 5, 5, 5, 5, 0, 5, 0, 0, 0, 0, 0, 6, 6, 6, 6, 6];
var ply = 0;
for (col in fill.values()) {
  let session = if (ply % 2 == 0) "red" else "yellow";
  let r = drop(session, col);
  ply += 1;
  if (ply < 42) {
    switch (r) {
      case (#gameEnded _) Runtime.trap("the fill must not end before the last disc");
      case (_) {};
    };
  } else {
    switch (r) {
      case (#gameEnded { verdict = #draw; steps = 42 }) {};
      case (_) Runtime.trap("the 42nd disc without a line must be a draw");
    };
  };
};
switch (t.status(spec, now, "yellow")) {
  case (#debrief d) {
    assert d.end == #finished(#draw);
    assert d.finalGame.winLine.size() == 0;
  };
  case (_) Runtime.trap("yellow should see the drawn debrief");
};
Debug.print("5. rematch and a full-board draw OK");

Debug.print("ALL ConnectFourRules LIFECYCLE CHECKS PASSED");
