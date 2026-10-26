/// The live game's types, translated literally from `VIEW (Candid)`,
/// `ACTION (Candid)` and `OPTIONS` of
/// https://co6yk-kyaaa-aaaau-ahgea-cai.raw.icp0.io/semantics.
/// Field and tag names must match exactly: the game sends its `View` in
/// every `MoveRequest` and decodes the `Action` reply against its own type.
module {

  /// `variant { p1; p2 }`: p1 = Red (drops first), p2 = Yellow.
  public type Seat = { #p1; #p2 };

  /// `record { col : nat; row : nat; seat : Seat }`
  public type LastMove = { col : Nat; row : Nat; seat : Seat };

  /// 42 cells, 7 columns by 6 rows, row-major from the bottom:
  /// index = row * 7 + col. `null` = empty.
  public type View = {
    board : [?Seat];
    lastMove : ?LastMove;
    winLine : [Nat];
  };

  /// `variant { drop : record { col : nat } }`
  public type Action = { #drop : { col : Nat } };

  /// `OPTIONS: none (type Options = record {})`
  public type Options = {};

};
