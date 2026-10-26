// Host actor for Connect Four, from the framework's template plus its
// optional canister players: bot canisters can take a seat and play.
// Every game read and mutation goes through `mo:duel-game-core/transport`.

import TP "mo:duel-game-core";
import Registry "mo:duel-game-core/registry";
import Transport "mo:duel-game-core/transport";
import TransportActorMixin "mo:duel-game-core/transport_actor_mixin";
import CanisterPlayers "mo:duel-game-core/canister_players";
import CanisterPlayersActorMixin "mo:duel-game-core/canister_players_actor_mixin";
import HttpActorMixin "mo:duel-game-core/http_actor_mixin";
import PT "mo:promtracker";
import Tracker "mo:promtracker/Tracker"; // brings `pt.toValue()` into scope

import BotIface "BotIface";
import Rules "ConnectFourRules";

actor {
  // Metrics: the registry's four game metrics plus promtracker's system
  // ones, served at GET /metrics (Prometheus exposition).
  let pt = PT.Tracker.new(); // plain data — stable
  transient let renderer = PT.Renderer(); // closures — rebuilt on upgrade
  renderer.addValue(PT.allSystemMetrics);
  renderer.addValue(pt.toValue());

  // All the data — tables, lobby, random-number generator. Stable.
  let duel = Transport.new<Rules.State, Rules.Action, Rules.Options>();
  duel.registry.setTimeouts(150_000_000_000, 120_000_000_000); // idle 150s, claim 120s; re-applied on every upgrade
  duel.registry.attachMetrics(pt); // games_started / active_games / rounds_per_game / matchmaking_wait_seconds
  let bots = CanisterPlayers.newStore(); // the bot directory and in-flight asks — stable

  // The function values the framework calls: the rules and the call that
  // asks a seated bot for its move. No leaderboard. Rebuilt on every
  // upgrade.
  transient let env : Transport.Env<Rules.State, Rules.Action, Rules.View, Rules.Options> = {
    spec = Rules.spec;
    bots = ?{ store = bots; call = BotIface.callBot };
    scoring = null;
  };

  // Every method that names none of the game's types, and the sweep timer.
  include TransportActorMixin<system>(duel.lobby(env));

  // The four methods whose Candid types name the game's own types.
  public shared ({ caller }) func duel_create_table(seat : TP.Seat, visibility : TP.TableVisibility, options : Rules.Options) : async Transport.Ack {
    await* duel.createTable<system, Rules.State, Rules.Action, Rules.View, Rules.Options>(env, caller, seat, visibility, options);
  };

  public shared query ({ caller }) func duel_lobby(rev : Nat) : async Transport.LobbyResult<Rules.Options> {
    duel.lobbyView(caller, rev);
  };

  public shared ({ caller }) func duel_submit(tableId : TP.TableId, gen : Nat, step : Nat, action : Rules.Action) : async Transport.Reply<Rules.View> {
    duel.reply(env, caller, tableId, await* duel.submit<system, Rules.State, Rules.Action, Rules.View, Rules.Options>(env, caller, tableId, gen, step, action));
  };

  public shared query ({ caller }) func duel_table(tableId : TP.TableId, rev : Nat) : async Transport.TableResult<Rules.View> {
    duel.table(env, caller, tableId, rev);
  };

  // GET /semantics — the rules text a third-party frontend is built from;
  // GET /metrics — the metrics above.
  include HttpActorMixin([
    ("/semantics", func() : Text = Rules.SEMANTICS),
    ("/metrics", renderer.renderExposition),
  ]);

  // join/leave/claim_win/reset/ack_ended_as_canister for seated bots, and
  // register_bot/unregister_bot/list_bots for discovery.
  include CanisterPlayersActorMixin(duel.canisterPlayers(env), bots.directory, null);
};
