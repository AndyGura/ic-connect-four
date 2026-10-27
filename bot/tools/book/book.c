// Opening-book generator. usage: book <maxPly> < roots
// Each root line is a move string (columns 0-6, Red first); the side to
// move at the root is the book's side ("hard"). From every position where
// hard is to move (up to maxPly discs down), prints "moves col value":
// a move that keeps the position's value (1 win first, else 0 draw), and
// expands every reply of the opponent. Lost positions end the line.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t u64;
static const u64 BOTTOM = 0x40810204081ULL;
static const u64 BOARD = 0xfdfbf7efdfbfULL;
static const int ORDER[7] = {3, 2, 4, 1, 5, 0, 6};

static inline u64 colmask(int c) { return 0x3fULL << (7 * c); }
static inline u64 possible(u64 mask) { return (mask + BOTTOM) & BOARD; }
static inline u64 winning(u64 pos, u64 mask) {
  u64 r = (pos << 1) & (pos << 2) & (pos << 3);
  u64 p = (pos << 7) & (pos << 14);
  r |= p & (pos << 21); r |= p & (pos >> 7);
  p = (pos >> 7) & (pos >> 14);
  r |= p & (pos << 7); r |= p & (pos >> 21);
  p = (pos << 6) & (pos << 12);
  r |= p & (pos << 18); r |= p & (pos >> 6);
  p = (pos >> 6) & (pos >> 12);
  r |= p & (pos << 6); r |= p & (pos >> 18);
  p = (pos << 8) & (pos << 16);
  r |= p & (pos << 24); r |= p & (pos >> 8);
  p = (pos >> 8) & (pos >> 16);
  r |= p & (pos << 8); r |= p & (pos >> 24);
  return r & (BOARD ^ mask);
}
static inline u64 mirror(u64 x) {
  u64 r = 0;
  for (int c = 0; c < 7; c++) r |= ((x >> (7 * c)) & 0x7fULL) << (7 * (6 - c));
  return r;
}

#define TT_BITS 25
typedef struct { u64 key; int8_t lo, hi, move; } Entry;
static Entry *tt;

static int negamax(u64 cur, u64 mask, int moves, int alpha, int beta) {
  u64 poss = possible(mask);
  if (winning(cur, mask) & poss) return 1;
  u64 opp = cur ^ mask, oppwin = winning(opp, mask), next = poss, forced = poss & oppwin;
  if (forced) {
    if (forced & (forced - 1)) return -1;
    next = forced;
  }
  next &= ~(oppwin >> 1);
  if (!next) return -1;
  if (moves >= 40) return 0;
  u64 key = cur + mask, mkey = mirror(cur) + mirror(mask);
  int flip = mkey < key;
  if (flip) key = mkey;
  Entry *e = &tt[(key * 0x9E3779B97F4A7C15ULL) >> (64 - TT_BITS)];
  int ttmove = -1;
  if (e->key == key) {
    if (e->lo >= beta) return e->lo;
    if (e->hi <= alpha) return e->hi;
    if (e->lo > alpha) alpha = e->lo;
    if (e->hi < beta) beta = e->hi;
    if (e->move >= 0) ttmove = flip ? 6 - e->move : e->move;
  }
  int cols[7], keys[7], n = 0;
  for (int i = 0; i < 7; i++) {
    int c = ORDER[i];
    u64 mv = next & colmask(c);
    if (!mv) continue;
    int k = __builtin_popcountll(winning(cur | mv, mask)) + (c == ttmove ? 100 : 0);
    int j = n++;
    while (j > 0 && keys[j - 1] < k) { cols[j] = cols[j - 1]; keys[j] = keys[j - 1]; j--; }
    cols[j] = c; keys[j] = k;
  }
  int a0 = alpha, best = -2, bestcol = -1;
  for (int i = 0; i < n; i++) {
    u64 mv = next & colmask(cols[i]);
    int v = -negamax(opp, mask | mv, moves + 1, -beta, -alpha);
    if (v > best) { best = v; bestcol = cols[i]; }
    if (v > alpha) alpha = v;
    if (alpha >= beta) break;
  }
  int8_t lo = -1, hi = 1;
  if (e->key == key) { lo = e->lo; hi = e->hi; }
  if (best >= beta) { if (best > lo) lo = best; }
  else if (best <= a0) { if (best < hi) hi = best; }
  else { lo = hi = best; }
  e->key = key; e->lo = lo; e->hi = hi;
  e->move = bestcol < 0 ? -1 : (flip ? 6 - bestcol : bestcol);
  return best;
}

// Hard-to-move positions already expanded (mirror-normalised keys).
#define SEEN_BITS 22
static u64 *seen;
static int seen_add(u64 key) {
  size_t i = (key * 0x9E3779B97F4A7C15ULL) >> (64 - SEEN_BITS);
  while (seen[i]) {
    if (seen[i] == key) return 0;
    i = (i + 1) & ((1u << SEEN_BITS) - 1);
  }
  seen[i] = key;
  return 1;
}

static int maxply;
static char line[64];

static void expand(u64 cur, u64 mask, int moves, int hard_to_move) {
  if (moves > maxply || moves >= 42) return;
  u64 poss = possible(mask);
  if (!hard_to_move) {
    for (int i = 0; i < 7; i++) {
      int c = ORDER[i];
      u64 mv = poss & colmask(c);
      if (!mv) continue;
      if (winning(cur, mask) & mv) continue; // the opponent wins: no book after that
      line[moves] = '0' + c; line[moves + 1] = 0;
      expand(cur ^ mask, mask | mv, moves + 1, 1);
    }
    return;
  }
  u64 nkey = cur + mask, mkey = mirror(cur) + mirror(mask);
  if (!seen_add(mkey < nkey ? mkey : nkey)) return;
  // Immediate win: no book needed, the line ends.
  if (winning(cur, mask) & poss) return;
  // Candidates in the solver's own order.
  int cols[7], keys[7], n = 0;
  for (int i = 0; i < 7; i++) {
    int c = ORDER[i];
    u64 mv = poss & colmask(c);
    if (!mv) continue;
    int k = __builtin_popcountll(winning(cur | mv, mask));
    int j = n++;
    while (j > 0 && keys[j - 1] < k) { cols[j] = cols[j - 1]; keys[j] = keys[j - 1]; j--; }
    cols[j] = c; keys[j] = k;
  }
  int pick = -1, value = -1;
  for (int i = 0; i < n && pick < 0; i++) {
    u64 mv = poss & colmask(cols[i]);
    if (negamax(cur ^ mask, mask | mv, moves + 1, -1, 0) <= -1) { pick = cols[i]; value = 1; }
  }
  for (int i = 0; i < n && pick < 0; i++) {
    u64 mv = poss & colmask(cols[i]);
    if (negamax(cur ^ mask, mask | mv, moves + 1, 0, 1) <= 0) { pick = cols[i]; value = 0; }
  }
  if (pick < 0) return; // lost: the search plays it
  line[moves] = 0;
  printf("%s %d %d\n", line, pick, value);
  fflush(stdout);
  u64 mv = poss & colmask(pick);
  line[moves] = '0' + pick; line[moves + 1] = 0;
  expand(cur ^ mask, mask | mv, moves + 1, 0);
}

int main(int argc, char **argv) {
  maxply = argc > 1 ? atoi(argv[1]) : 8;
  tt = calloc((size_t)1 << TT_BITS, sizeof(Entry));
  seen = calloc((size_t)1 << SEEN_BITS, sizeof(u64));
  char root[64];
  while (fgets(root, sizeof root, stdin)) {
    root[strcspn(root, "\r\n")] = 0;
    u64 cur = 0, mask = 0;
    int moves = 0;
    for (char *s = root; *s; s++) {
      int c = *s - '0';
      u64 mv = (mask + (1ULL << (7 * c))) & colmask(c);
      cur ^= mask; mask |= mv; moves++;
    }
    strcpy(line, root);
    expand(cur, mask, moves, 1);
  }
  return 0;
}
