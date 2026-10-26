// Weak Connect Four solver: for each position read from stdin (a string
// of columns 0-6, Red first), prints its value for the side to move
// (1 win, 0 draw, -1 loss) and the value of each move (x = column full),
// e.g. "334 -> 1 | 0 1 -1 1 0 -1 x". Exact; bitboards as in Search.mo.
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

static int has_four(u64 pos) {
  u64 m = pos & (pos >> 7); if (m & (m >> 14)) return 1;
  m = pos & (pos >> 6); if (m & (m >> 12)) return 1;
  m = pos & (pos >> 8); if (m & (m >> 16)) return 1;
  m = pos & (pos >> 1); return (m & (m >> 2)) != 0;
}

#ifndef TT_BITS
#define TT_BITS 25
#endif
typedef struct { u64 key; int8_t lo, hi, move; } Entry;
static Entry *tt;
static unsigned long long nodes;

static inline u64 mirror(u64 x) {
  u64 r = 0;
  for (int c = 0; c < 7; c++) r |= ((x >> (7 * c)) & 0x7fULL) << (7 * (6 - c));
  return r;
}

static int negamax(u64 cur, u64 mask, int moves, int alpha, int beta) {
  nodes++;
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

// Value of the position for the side to move.
static int solve(u64 cur, u64 mask, int moves) {
  if (winning(cur, mask) & possible(mask)) return 1;
  if (moves == 42) return 0;
  if (negamax(cur, mask, moves, 0, 1) >= 1) return 1;
  if (negamax(cur, mask, moves, -1, 0) >= 0) return 0;
  return -1;
}

int main(void) {
  tt = calloc((size_t)1 << TT_BITS, sizeof(Entry));
  char line[128];
  while (fgets(line, sizeof line, stdin)) {
    line[strcspn(line, "\r\n")] = 0;
    u64 cur = 0, mask = 0;
    int moves = 0, bad = 0;
    for (char *s = line; *s; s++) {
      int c = *s - '0';
      if (c < 0 || c > 6 || (mask & (1ULL << (7 * c + 5)))) { bad = 1; break; }
      u64 mv = (mask + (1ULL << (7 * c))) & colmask(c);
      cur ^= mask; mask |= mv; moves++;
      if (has_four(cur ^ mask)) { bad = 1; break; }
    }
    if (bad) { printf("%s -> invalid\n", line); fflush(stdout); continue; }
    nodes = 0;
    int v = solve(cur, mask, moves);
    printf("%s -> %d |", line, v);
    for (int c = 0; c < 7; c++) {
      if (mask & (1ULL << (7 * c + 5))) { printf(" x"); continue; }
      u64 mv = (mask + (1ULL << (7 * c))) & colmask(c);
      u64 mine = cur | mv;
      if (has_four(mine)) { printf(" 1"); continue; }
      printf(" %d", -solve(cur ^ mask, mask | mv, moves + 1));
    }
    printf(" | %llu nodes\n", nodes);
    fflush(stdout);
  }
  return 0;
}
