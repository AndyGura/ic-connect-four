import Int64 "mo:core/Int64";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import VarArray "mo:core/VarArray";

import Book "Book";

/// A Connect Four searcher over bitboards. Two searches share one budget:
///
/// - an exact one (`solveFrom` discs on): win, draw or loss with perfect
///   play from both sides, no depth limit, its own share of the budget;
/// - a heuristic one: negamax with alpha-beta (principal variation
///   search), a transposition table and iterative deepening, scoring the
///   horizon with `score`. It decides when the exact search ran out of
///   budget, and picks among the moves the exact search found equal.
///
/// No actor, no `Time`, no storage: the caller passes its budget, in
/// nodes (`maxNodes`) and in its own work units (`maxWork` against
/// `clock`; instructions in the canister).
///
/// Bit `col * 7 + row` is cell (col, row), row 0 at the bottom. Each
/// column has a seventh, always empty bit on top, so shifts never carry a
/// line from one column into the next. A position is `cur` (the discs of
/// the seat on turn), `mask` (every disc) and `moves` (how many).
///
/// The hot paths use fixed-width numbers only: in Motoko an `Int`
/// subtraction costs about seventy times an `Int64` one.
module {

  /// A win with the k-th disc of the game scores `WIN - k` for the winner.
  public let WIN : Int64 = 100_000;
  let INF : Int64 = 1_000_000;

  /// Above this, a score is a proven win (below its negation, a loss).
  public let PROVEN : Int64 = 99_900;

  let BOTTOM : Nat64 = 0x40810204081; // row 0 of every column
  let BOARD : Nat64 = 0xfdfbf7efdfbf; // every playable cell
  let ROWS_024 : Nat64 = 0x54a952a54a95; // rows 1, 3, 5 counted from 1: Red's
  let ROWS_135 : Nat64 = 0xa952a54a952a; // rows 2, 4, 6 counted from 1: Yellow's

  // The cell weights (how many lines of four pass through each cell),
  // one mask per bit of the weight:
  //   3 4  5  7  5 4 3   (rows 0 and 5)
  //   4 6  8 10  8 6 4   (rows 1 and 4)
  //   5 8 11 13 11 8 5   (rows 2 and 3)
  let W1 : Nat64 = 0xb402d5ab402d;
  let W2 : Nat64 = 0x8490c6630921;
  let W4 : Nat64 = 0x799a15a8599e;
  let W8 : Nat64 = 0x61e3c78600;

  /// Centre first: the usual best-first guess before any search.
  public let ORDER : [Nat] = [3, 2, 4, 1, 5, 0, 6];
  let COLUMN : [Nat64] = [0x3f, 0x1f80, 0xfc000, 0x7e00000, 0x3f0000000, 0x1f800000000, 0xfc0000000000];

  // Heuristic weights, in cell-weight units.
  let THREAT : Nat64 = 12; // an empty cell that would complete four
  let PARITY : Nat64 = 14; // ...on a row that favours its owner (Allis' rule)
  let STACKED : Nat64 = 24; // ...with another threat of the same seat right above

  public func columnMask(col : Nat) : Nat64 = COLUMN[col];

  /// The cells a disc can be dropped into now, one per open column.
  public func possible(mask : Nat64) : Nat64 = (mask + BOTTOM) & BOARD;

  public func popcount(x : Nat64) : Nat = Nat64.bitcountNonZero(x).toNat();

  /// The empty cells that would complete four or more for `pos`.
  public func winningCells(pos : Nat64, mask : Nat64) : Nat64 {
    // vertical
    var r = (pos << 1) & (pos << 2) & (pos << 3);
    // horizontal
    var p = (pos << 7) & (pos << 14);
    r |= p & (pos << 21);
    r |= p & (pos >> 7);
    p := (pos >> 7) & (pos >> 14);
    r |= p & (pos << 7);
    r |= p & (pos >> 21);
    // diagonal, down to the right
    p := (pos << 6) & (pos << 12);
    r |= p & (pos << 18);
    r |= p & (pos >> 6);
    p := (pos >> 6) & (pos >> 12);
    r |= p & (pos << 6);
    r |= p & (pos >> 18);
    // diagonal, up to the right
    p := (pos << 8) & (pos << 16);
    r |= p & (pos << 24);
    r |= p & (pos >> 8);
    p := (pos >> 8) & (pos >> 16);
    r |= p & (pos << 8);
    r |= p & (pos >> 24);
    r & (BOARD ^ mask);
  };

  /// Whether `pos` already holds four in a row somewhere.
  public func hasFour(pos : Nat64) : Bool {
    var m = pos & (pos >> 7);
    if (m & (m >> 14) != 0) return true;
    m := pos & (pos >> 6);
    if (m & (m >> 12) != 0) return true;
    m := pos & (pos >> 8);
    if (m & (m >> 16) != 0) return true;
    m := pos & (pos >> 1);
    m & (m >> 2) != 0;
  };

  func weighted(x : Nat64) : Nat64 {
    Nat64.bitcountNonZero(x & W1) + (Nat64.bitcountNonZero(x & W2) << 1) + (Nat64.bitcountNonZero(x & W4) << 2) + (Nat64.bitcountNonZero(x & W8) << 3);
  };

  func threatScore(threats : Nat64, good : Nat64) : Nat64 {
    THREAT * Nat64.bitcountNonZero(threats) + PARITY * Nat64.bitcountNonZero(threats & good) + STACKED * Nat64.bitcountNonZero(threats & (threats >> 1));
  };

  /// The heuristic score of a position for the seat on turn, given both
  /// seats' winning cells.
  public func score(cur : Nat64, mask : Nat64, moves : Nat64, curWin : Nat64, oppWin : Nat64) : Int64 {
    // The seat on turn is Red when an even number of discs is down.
    let curGood = if (moves & 1 == 0) ROWS_024 else ROWS_135;
    let mine = weighted(cur) + threatScore(curWin, curGood);
    let theirs = weighted(cur ^ mask) + threatScore(oppWin, BOARD ^ curGood);
    Int64.fromNat64(mine) - Int64.fromNat64(theirs);
  };

  let ZUGZWANG : Nat64 = 48; // the only seat with a threat on its own rows

  /// `score`, with Allis' threat rules on top: a threat right above an
  /// opponent's threat is dead (the cell below decides first), and the
  /// one seat holding live threats on its own rows controls the zugzwang
  /// at the end of the game.
  public func scoreRules(cur : Nat64, mask : Nat64, moves : Nat64, curWin : Nat64, oppWin : Nat64) : Int64 {
    let curGood = if (moves & 1 == 0) ROWS_024 else ROWS_135;
    let oppGood = BOARD ^ curGood;
    let curLive = curWin & ^(oppWin << 1);
    let oppLive = oppWin & ^(curWin << 1);
    var mine = weighted(cur) + threatScore(curLive, curGood);
    var theirs = weighted(cur ^ mask) + threatScore(oppLive, oppGood);
    let curZ = curLive & curGood;
    let oppZ = oppLive & oppGood;
    if (curZ != 0 and oppZ == 0) mine += ZUGZWANG else if (oppZ != 0 and curZ == 0) theirs += ZUGZWANG;
    Int64.fromNat64(mine) - Int64.fromNat64(theirs);
  };

  public func evaluate(cur : Nat64, mask : Nat64, moves : Nat64) : Int64 {
    score(cur, mask, moves, winningCells(cur, mask), winningCells(cur ^ mask, mask));
  };

  public type Settings = {
    /// Plies searched below the root move; iterative deepening stops there.
    maxDepth : Nat;
    /// Root moves scoring within `margin` of the best are picked at random.
    margin : Int64;
    /// Searches one ply on when the depth limit is hit with a forced block.
    extendForced : Bool;
    /// The budget: nodes, and work units on `clock` (0: none).
    maxNodes : Nat;
    maxWork : Nat;
    /// With at least this many discs down, the exact search goes first
    /// (43: never), within `solveShare` percent of the budget.
    solveFrom : Nat;
    solveShare : Nat;
    ttSize : Nat;
    /// Scores the horizon with `scoreRules` rather than `score`.
    rules : Bool;
    /// Plays the opening book's move wherever it has one.
    book : Bool;
  };

  public type Result = {
    col : Nat;
    score : Int64;
    /// The deepest heuristic iteration that completed (0: none was needed).
    depth : Nat;
    nodes : Nat;
    /// The exact value for the mover (1 win, 0 draw, -1 loss), when solved.
    exact : ?Int;
  };

  // Transposition-table entry flags.
  let EXACT : Nat64 = 0;
  let LOWER : Nat64 = 1;
  let UPPER : Nat64 = 2;

  public class Searcher(settings : Settings, clock : () -> Nat) {

    let size = Nat.max(settings.ttSize, 1);
    let size64 = size.toNat64();
    // The heuristic search's table, and the exact search's.
    let ttKey = VarArray.repeat<Nat64>(0, size);
    let ttScore = VarArray.repeat<Int64>(0, size);
    let ttMeta = VarArray.repeat<Nat64>(0, size); // depth << 5 | flag << 3 | col
    let exKey = VarArray.repeat<Nat64>(0, size);
    let exBounds = VarArray.repeat<Nat64>(0, size); // (lo + 1) * 3 + (hi + 1)
    // Per-position move lists, indexed by discs down, so a node allocates
    // nothing.
    let bufCol = VarArray.tabulate<[var Nat]>(43, func _ = VarArray.repeat<Nat>(0, 7));
    let bufKey = VarArray.tabulate<[var Nat64]>(43, func _ = VarArray.repeat<Nat64>(0, 7));
    let extend = settings.extendForced;
    let rules = settings.rules;

    var nodes : Nat64 = 0;
    var aborted = false;
    var capNodes = settings.maxNodes.toNat64();
    var capWork = settings.maxWork;

    func checkBudget() {
      if (nodes >= capNodes or (capWork > 0 and nodes & 255 == 0 and clock() >= capWork)) aborted := true;
    };

    /// Orders the columns of `next` (at most 7) best-first into
    /// `bufCol[moves]`; answers how many there are. With `threats`, a move
    /// that makes more winning cells goes first; centre first otherwise.
    func orderMoves(cur : Nat64, mask : Nat64, moves : Nat, next : Nat64, ttCol : Nat, threats : Bool) : Nat {
      let cols = bufCol[moves];
      let keys = bufKey[moves];
      var n = 0;
      for (col in ORDER.values()) {
        let mv = next & COLUMN[col];
        if (mv != 0) {
          var key : Nat64 = if (threats) Nat64.bitcountNonZero(winningCells(cur | mv, mask)) else 0;
          if (col == ttCol) key += 100;
          // Insertion sort, stable: ties keep the centre-first order.
          var i = n;
          while (i > 0 and keys[i - 1] < key) {
            cols[i] := cols[i - 1];
            keys[i] := keys[i - 1];
            i -= 1;
          };
          cols[i] := col;
          keys[i] := key;
          n += 1;
        };
      };
      n;
    };

    /// Heuristic negamax over the position (`cur` on turn), `moves` discs
    /// down. Scores are for `cur`: `WIN - k` for a win with the game's
    /// k-th disc, its negation for a loss, `score` at the horizon.
    func negamax(cur : Nat64, mask : Nat64, moves : Nat, depthIn : Nat, alphaIn : Int64, betaIn : Int64) : Int64 {
      nodes += 1;
      checkBudget();
      if (aborted) return 0;

      let m64 = moves.toNat64();
      let poss = possible(mask);
      let curWin = winningCells(cur, mask);
      if (curWin & poss != 0) return WIN - Int64.fromNat64(m64 + 1);

      let opp = cur ^ mask;
      let oppWin = winningCells(opp, mask);
      var next = poss;
      let forced = poss & oppWin;
      if (forced != 0) {
        // Two open threats: only one can be blocked.
        if (forced & (forced -% 1) != 0) return Int64.fromNat64(m64 + 2) - WIN;
        next := forced;
      };
      // Never drop right under a cell the opponent would win on.
      next &= ^(oppWin >> 1);
      if (next == 0) return Int64.fromNat64(m64 + 2) - WIN;
      // Two cells left, no win now and a safe move: nobody can win.
      if (m64 >= 40) return 0;

      var depth = depthIn;
      if (depth == 0) {
        if (extend and forced != 0) depth := 1 else if (rules) return scoreRules(cur, mask, m64, curWin, oppWin) else return score(cur, mask, m64, curWin, oppWin);
      };

      var alpha = alphaIn;
      var beta = betaIn;
      let key = cur + mask;
      let slot = (key % size64).toNat();
      var ttCol = 7;
      if (ttKey[slot] == key) {
        let meta = ttMeta[slot];
        ttCol := (meta & 7).toNat();
        if (meta >> 5 >= depth.toNat64()) {
          let s = ttScore[slot];
          let flag = (meta >> 3) & 3;
          if (flag == EXACT) return s;
          if (flag == LOWER and s > alpha) alpha := s;
          if (flag == UPPER and s < beta) beta := s;
          if (alpha >= beta) return s;
        };
      };
      let alphaOrig = alpha;

      let n = orderMoves(cur, mask, moves, next, ttCol, depth >= 3);
      let cols = bufCol[moves];
      var best = -INF;
      var bestCol = 7;
      var i = 0;
      label children while (i < n) {
        let col = cols[i];
        let child = mask | (next & COLUMN[col]);
        var s : Int64 = 0;
        if (i == 0) {
          s := -negamax(opp, child, moves + 1, depth - 1, -beta, -alpha);
        } else {
          // A null window first: is this move any better than the best?
          s := -negamax(opp, child, moves + 1, depth - 1, -alpha - 1, -alpha);
          if (not aborted and s > alpha and s < beta) s := -negamax(opp, child, moves + 1, depth - 1, -beta, -alpha);
        };
        if (aborted) return 0;
        if (s > best) {
          best := s;
          bestCol := col;
        };
        if (s > alpha) alpha := s;
        if (alpha >= beta) break children;
        i += 1;
      };

      let flag = if (best <= alphaOrig) UPPER else if (best >= beta) LOWER else EXACT;
      ttKey[slot] := key;
      ttScore[slot] := best;
      ttMeta[slot] := (depth.toNat64() << 5) | (flag << 3) | bestCol.toNat64();
      best;
    };

    /// Exact negamax: 1 win, 0 draw, -1 loss for `cur`, fail-soft
    /// within (`alphaIn`, `betaIn`).
    func exact(cur : Nat64, mask : Nat64, moves : Nat, alphaIn : Int64, betaIn : Int64) : Int64 {
      nodes += 1;
      checkBudget();
      if (aborted) return 0;

      let poss = possible(mask);
      if (winningCells(cur, mask) & poss != 0) return 1;
      let opp = cur ^ mask;
      let oppWin = winningCells(opp, mask);
      var next = poss;
      let forced = poss & oppWin;
      if (forced != 0) {
        if (forced & (forced -% 1) != 0) return -1;
        next := forced;
      };
      next &= ^(oppWin >> 1);
      if (next == 0) return -1;
      if (moves >= 40) return 0;

      var alpha = alphaIn;
      var beta = betaIn;
      let key = cur + mask;
      let slot = (key % size64).toNat();
      var lo : Int64 = -1;
      var hi : Int64 = 1;
      if (exKey[slot] == key) {
        let b = exBounds[slot];
        lo := Int64.fromNat64(b / 3) - 1;
        hi := Int64.fromNat64(b % 3) - 1;
        if (lo >= beta) return lo;
        if (hi <= alpha) return hi;
        if (lo > alpha) alpha := lo;
        if (hi < beta) beta := hi;
      };
      let a0 = alpha;

      let n = orderMoves(cur, mask, moves, next, 7, true);
      let cols = bufCol[moves];
      var best : Int64 = -1;
      var i = 0;
      label children while (i < n) {
        let v = -exact(opp, mask | (next & COLUMN[cols[i]]), moves + 1, -beta, -alpha);
        if (aborted) return 0;
        if (v > best) best := v;
        if (v > alpha) alpha := v;
        if (alpha >= beta) break children;
        i += 1;
      };

      if (best >= beta) { if (best > lo) lo := best } else if (best <= a0) {
        if (best < hi) hi := best;
      } else {
        lo := best;
        hi := best;
      };
      exKey[slot] := key;
      exBounds[slot] := Int64.toNat64(lo + 1) * 3 + Int64.toNat64(hi + 1);
      best;
    };

    func result(col : Nat, score : Int64, depth : Nat, exact : ?Int) : Result {
      { col; score; depth; nodes = nodes.toNat(); exact };
    };

    /// The move for the seat on turn (`cur`), `moves` discs down. `seed`
    /// picks among root moves within `settings.margin` of the best.
    public func best(cur : Nat64, mask : Nat64, moves : Nat, seed : Nat64) : Result {
      let poss = possible(mask);
      let opp = cur ^ mask;
      let win = winningCells(cur, mask) & poss;
      if (win != 0) return result(lowestCol(win), WIN - Int64.fromNat64(moves.toNat64() + 1), 0, ?1);
      if (settings.book) {
        switch (Book.lookup(cur, mask)) {
          case (?(col, wins)) if (poss & COLUMN[col] != 0) return result(col, if wins PROVEN else 0, 0, ?(if wins 1 else 0));
          case _ {};
        };
      };

      // The root's candidates: a forced block if there is one, and never
      // a drop under an opponent's winning cell while another move exists.
      let oppWin = winningCells(opp, mask);
      var cand = poss;
      let forced = poss & oppWin;
      if (forced != 0) cand := forced;
      let safe = cand & ^(oppWin >> 1);
      if (safe != 0) cand := safe;

      let roots = VarArray.repeat<Nat>(7, 7);
      var n = orderMoves(cur, mask, moves, cand, 7, true);
      for (i in Nat.range(0, n)) roots[i] := bufCol[moves][i];
      if (n == 0) return result(0, 0, 0, null);
      if (n == 1) return result(roots[0], 0, 0, null);

      // The exact search, within its share of the budget: a winning move
      // ends the search; otherwise the drawing moves, if any, are what the
      // heuristic search may choose from.
      var solved : ?Int = null;
      if (moves >= settings.solveFrom) {
        capNodes := (settings.maxNodes * settings.solveShare / 100).toNat64();
        capWork := settings.maxWork * settings.solveShare / 100;
        label wins for (i in Nat.range(0, n)) {
          let col = roots[i];
          let v = -exact(opp, mask | (cand & COLUMN[col]), moves + 1, -1, 0);
          if (aborted) break wins;
          if (v >= 1) return result(col, PROVEN, 0, ?1);
        };
        if (not aborted) {
          var draws = 0;
          label draws_ for (i in Nat.range(0, n)) {
            let col = roots[i];
            let v = -exact(opp, mask | (cand & COLUMN[col]), moves + 1, 0, 1);
            if (aborted) break draws_;
            if (v >= 0) {
              roots[draws] := col;
              draws += 1;
            };
          };
          if (draws > 0) {
            // Drawing moves only (all of them, unless the budget ran out).
            n := draws;
            solved := ?0;
          } else if (not aborted) solved := ?(-1);
        };
        aborted := false;
        capNodes := settings.maxNodes.toNat64();
        capWork := settings.maxWork;
        if (n == 1) return result(roots[0], 0, 0, solved);
      };

      // Scores of the last completed iteration, in `roots` order.
      var done : ?[var Int64] = null;
      var doneDepth = 0;
      let maxDepth = Nat.min(settings.maxDepth, 42 - moves);
      var d = 1;
      label deepen while (d <= maxDepth) {
        let scores = VarArray.repeat<Int64>(-INF, n);
        var bestScore = -INF;
        var alpha = -INF;
        var completed = 0;
        label roots_ while (completed < n) {
          let col = roots[completed];
          let s = -negamax(opp, mask | (cand & COLUMN[col]), moves + 1, d - 1, -INF, -alpha);
          if (aborted) break roots_;
          scores[completed] := s;
          if (s > bestScore) {
            bestScore := s;
            alpha := bestScore - settings.margin - 1;
          };
          completed += 1;
        };
        if (aborted) {
          // A partial iteration still counts once the previous best (searched
          // first) is scored: anything chosen then scores at least as well.
          if (completed >= 1) {
            for (i in Nat.range(completed, n)) scores[i] := -INF;
            done := ?scores;
            doneDepth := d;
          };
          break deepen;
        };
        done := ?scores;
        doneDepth := d;
        if (bestScore >= PROVEN or bestScore <= -PROVEN) break deepen;
        // Best first for the next iteration (stable sort by score).
        sortRoots(roots, scores, n);
        d += 1;
      };

      let ?scores = done else return result(roots[0], 0, 0, solved);
      var top = -INF;
      for (i in Nat.range(0, n)) { if (scores[i] > top) top := scores[i] };
      // Moves within the margin; a proven win is only ever traded for one
      // at least as good, never for a heuristic score.
      let floor = if (top >= PROVEN) top else top - settings.margin;
      var count = 0;
      for (i in Nat.range(0, n)) { if (scores[i] >= floor) count += 1 };
      var pick = (seed % Nat.max(count, 1).toNat64()).toNat();
      for (i in Nat.range(0, n)) {
        if (scores[i] >= floor) {
          if (pick == 0) return result(roots[i], scores[i], doneDepth, solved);
          pick -= 1;
        };
      };
      result(roots[0], top, doneDepth, solved);
    };

  };

  func lowestCol(cells : Nat64) : Nat {
    Nat64.bitcountTrailingZero(cells).toNat() / 7;
  };

  // Stable insertion sort of `roots[0..n)` by `scores`, best first.
  func sortRoots(roots : [var Nat], scores : [var Int64], n : Nat) {
    var i = 1;
    while (i < n) {
      let c = roots[i];
      let s = scores[i];
      var j = i;
      while (j > 0 and scores[j - 1] < s) {
        roots[j] := roots[j - 1];
        scores[j] := scores[j - 1];
        j -= 1;
      };
      roots[j] := c;
      scores[j] := s;
      i += 1;
    };
  };

  /// `cur`/`mask`/`moves` of a `View` board (index = row * 7 + col) for `seat`.
  public func fromCells(isMine : Nat -> ?Bool) : (Nat64, Nat64, Nat) {
    var cur : Nat64 = 0;
    var mask : Nat64 = 0;
    var moves = 0;
    for (row in Nat.range(0, 6)) {
      for (col in Nat.range(0, 7)) {
        switch (isMine(row * 7 + col)) {
          case (?mine) {
            let bit : Nat64 = 1 << (col * 7 + row).toNat64();
            mask |= bit;
            if (mine) cur |= bit;
            moves += 1;
          };
          case null {};
        };
      };
    };
    (cur, mask, moves);
  };

};
