import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import VarArray "mo:core/VarArray";

/// A Connect Four searcher over bitboards: negamax with alpha-beta, a
/// transposition table and iterative deepening, with a heuristic score
/// at the depth limit. No actor, no `Time`, no storage: the caller passes
/// its budget (`maxNodes`, and `outOfTime` for an instruction limit).
///
/// Bit `col * 7 + row` is cell (col, row), row 0 at the bottom. Each
/// column has a seventh, always empty bit on top, so shifts never carry a
/// line from one column into the next. A position is `cur` (the discs of
/// the seat on turn) and `mask` (every disc).
module {

  public let WIN : Int = 100_000;
  let INF : Int = 1_000_000;

  /// Above this, a score is a proven win (below its negation, a loss).
  public let PROVEN : Int = 99_900;

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

  // Heuristic weights, in cell-weight units.
  let THREAT : Int = 12; // an empty cell that would complete four
  let PARITY : Int = 14; // ...on a row that favours its owner (Allis' rule)
  let STACKED : Int = 24; // ...with another threat of the same seat right above

  public func columnMask(col : Nat) : Nat64 = 0x3f << Nat.toNat64(col * 7);

  /// The cells a disc can be dropped into now, one per open column.
  public func possible(mask : Nat64) : Nat64 = (mask + BOTTOM) & BOARD;

  public func popcount(x : Nat64) : Nat = Nat64.toNat(Nat64.bitcountNonZero(x));

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

  func weighted(x : Nat64) : Int {
    popcount(x & W1) + 2 * popcount(x & W2) + 4 * popcount(x & W4) + 8 * popcount(x & W8);
  };

  func threatScore(threats : Nat64, good : Nat64) : Int {
    THREAT * popcount(threats) + PARITY * popcount(threats & good) + STACKED * popcount(threats & (threats >> 1));
  };

  /// The heuristic score of a position for the seat on turn.
  public func evaluate(cur : Nat64, mask : Nat64, moves : Nat) : Int {
    let opp = cur ^ mask;
    // The seat on turn is Red when an even number of discs is down.
    let (curGood, oppGood) = if (moves % 2 == 0) (ROWS_024, ROWS_135) else (ROWS_135, ROWS_024);
    weighted(cur) - weighted(opp) + threatScore(winningCells(cur, mask), curGood) - threatScore(winningCells(opp, mask), oppGood);
  };

  public type Settings = {
    /// Plies searched below the root move; iterative deepening stops there.
    maxDepth : Nat;
    /// Root moves scoring within `margin` of the best are picked at random.
    margin : Int;
    /// Searches one ply on when the depth limit is hit with a forced block.
    extendForced : Bool;
    maxNodes : Nat;
    ttSize : Nat;
  };

  public type Result = {
    col : Nat;
    score : Int;
    /// The deepest iteration that completed (0: decided without search).
    depth : Nat;
    nodes : Nat;
  };

  // Transposition-table entry flags.
  let EXACT = 0;
  let LOWER = 1;
  let UPPER = 2;

  public class Searcher(settings : Settings, outOfTime : () -> Bool) {

    let size = Nat.max(settings.ttSize, 1);
    let size64 = Nat.toNat64(size);
    let ttKey = VarArray.repeat<Nat64>(0, size);
    let ttScore = VarArray.repeat<Int>(0, size);
    let ttMeta = VarArray.repeat<Nat>(0, size); // depth * 32 + flag * 8 + col
    // Per-ply move lists, so a node allocates nothing.
    let bufCol = VarArray.tabulate<[var Nat]>(43, func _ = VarArray.repeat<Nat>(0, 7));
    let bufKey = VarArray.tabulate<[var Int]>(43, func _ = VarArray.repeat<Int>(0, 7));

    public var nodes = 0;
    var aborted = false;

    func checkBudget() {
      if (nodes >= settings.maxNodes or (nodes % 256 == 0 and outOfTime())) aborted := true;
    };

    /// Orders the columns of `next` (at most 7) best-first into
    /// `bufCol[ply]`; answers how many there are.
    func orderMoves(cur : Nat64, mask : Nat64, next : Nat64, ttCol : Nat, depth : Nat, ply : Nat) : Nat {
      let cols = bufCol[ply];
      let keys = bufKey[ply];
      var n = 0;
      for (col in ORDER.values()) {
        let mv = next & columnMask(col);
        if (mv != 0) {
          // Near the leaves the centre-first order is cheaper than counting threats.
          var key : Int = if (depth >= 3) popcount(winningCells(cur | mv, mask)) else 0;
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

    /// Negamax over the position (`cur` on turn), `ply` moves below the
    /// root. Scores are for `cur`: `WIN - k` for a win on the k-th move
    /// from the root, its negation for a loss, `evaluate` at the horizon.
    func negamax(cur : Nat64, mask : Nat64, moves : Nat, depthIn : Nat, alphaIn : Int, betaIn : Int, ply : Nat) : Int {
      nodes += 1;
      checkBudget();
      if (aborted) return 0;

      let opp = cur ^ mask;
      let poss = possible(mask);
      if (winningCells(cur, mask) & poss != 0) return WIN - (ply + 1);

      let oppWin = winningCells(opp, mask);
      var next = poss;
      let forced = poss & oppWin;
      if (forced != 0) {
        // Two open threats: only one can be blocked.
        if (forced & (forced -% 1) != 0) return -(WIN - (ply + 2));
        next := forced;
      };
      // Never drop right under a cell the opponent would win on.
      next &= ^(oppWin >> 1);
      if (next == 0) return -(WIN - (ply + 2));
      // Two cells left, no win now and a safe move: nobody can win.
      if (moves + 2 >= 42) return 0;

      var depth = depthIn;
      if (depth == 0) {
        if (settings.extendForced and forced != 0) depth := 1 else return evaluate(cur, mask, moves);
      };

      var alpha = alphaIn;
      var beta = betaIn;
      let key = cur + mask;
      let slot = Nat64.toNat(key % size64);
      var ttCol = 7;
      if (ttKey[slot] == key) {
        let meta = ttMeta[slot];
        ttCol := meta % 8;
        if (meta / 32 >= depth) {
          let s = ttScore[slot];
          let flag = (meta / 8) % 4;
          if (flag == EXACT) return s;
          if (flag == LOWER and s > alpha) alpha := s;
          if (flag == UPPER and s < beta) beta := s;
          if (alpha >= beta) return s;
        };
      };
      let alphaOrig = alpha;

      let n = orderMoves(cur, mask, next, ttCol, depth, ply);
      let cols = bufCol[ply];
      var best = -INF;
      var bestCol = 7;
      var i = 0;
      label children while (i < n) {
        let col = cols[i];
        let mv = next & columnMask(col);
        let s = -negamax(opp, mask | mv, moves + 1, depth - 1, -beta, -alpha, ply + 1);
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
      ttMeta[slot] := depth * 32 + flag * 8 + bestCol;
      best;
    };

    /// The move for the seat on turn (`cur`), `moves` discs down. `seed`
    /// picks among root moves within `settings.margin` of the best.
    public func best(cur : Nat64, mask : Nat64, moves : Nat, seed : Nat64) : Result {
      let poss = possible(mask);
      let opp = cur ^ mask;
      let win = winningCells(cur, mask) & poss;
      if (win != 0) return { col = lowestCol(win); score = WIN - 1; depth = 0; nodes };

      // The root's candidates: a forced block if there is one, and never
      // a drop under an opponent's winning cell while another move exists.
      let oppWin = winningCells(opp, mask);
      var cand = poss;
      let forced = poss & oppWin;
      if (forced != 0) cand := forced;
      let safe = cand & ^(oppWin >> 1);
      if (safe != 0) cand := safe;

      let roots = VarArray.repeat<Nat>(7, 7);
      var n = 0;
      for (col in ORDER.values()) {
        if (cand & columnMask(col) != 0) {
          roots[n] := col;
          n += 1;
        };
      };
      if (n == 0) return { col = 0; score = 0; depth = 0; nodes };
      if (n == 1) return { col = roots[0]; score = 0; depth = 0; nodes };

      // Scores of the last completed iteration, in `roots` order.
      var done : ?[var Int] = null;
      var doneDepth = 0;
      let maxDepth = Nat.min(settings.maxDepth, 42 - moves);
      var d = 1;
      label deepen while (d <= maxDepth) {
        let scores = VarArray.repeat<Int>(-INF, n);
        var bestScore = -INF;
        var alpha = -INF;
        var completed = 0;
        label roots_ while (completed < n) {
          let col = roots[completed];
          let s = -negamax(opp, mask | (cand & columnMask(col)), moves + 1, d - 1, -INF, -alpha, 1);
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

      let ?scores = done else return { col = roots[0]; score = 0; depth = 0; nodes };
      var top = -INF;
      for (i in Nat.range(0, n)) { if (scores[i] > top) top := scores[i] };
      // Moves within the margin; a proven win is only ever traded for one
      // at least as good, never for a heuristic score.
      let floor = if (top >= PROVEN) top else top - settings.margin;
      var count = 0;
      for (i in Nat.range(0, n)) { if (scores[i] >= floor) count += 1 };
      var pick = Nat64.toNat(seed % Nat.toNat64(Nat.max(count, 1)));
      for (i in Nat.range(0, n)) {
        if (scores[i] >= floor) {
          if (pick == 0) return { col = roots[i]; score = scores[i]; depth = doneDepth; nodes };
          pick -= 1;
        };
      };
      { col = roots[0]; score = top; depth = doneDepth; nodes };
    };

  };

  func lowestCol(cells : Nat64) : Nat {
    Nat64.toNat(Nat64.bitcountTrailingZero(cells)) / 7;
  };

  // Stable insertion sort of `roots[0..n)` by `scores`, best first.
  func sortRoots(roots : [var Nat], scores : [var Int], n : Nat) {
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
            let bit : Nat64 = 1 << Nat.toNat64(col * 7 + row);
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
