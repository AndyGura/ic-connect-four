// Playing against bots: the bot dialog in the panel, the lobby's and the
// waiting screen's way into it, and a rematch against a bot re-inviting it.
//
// A bot is any canister registered with the backend (`list_bots`), each
// listed once per level it plays. Challenging one calls that canister's own
// `play(backend, table, seat, code, level)`, which seats it through the
// backend's `join_table_as_canister`; from then on the backend asks the bot
// for every drop it is due. See duel-game-core's frontend README, "Bot
// registry".

import { Actor } from "@icp-sdk/core/agent";
import { Principal } from "@icp-sdk/core/principal";
import { buildBotPlayIdlFactory } from "@research-ag/duel-game-core/idl.js";
import { atTableOf, errText, viewOf } from "@research-ag/duel-game-core/client.js";
import { botDisplayName, esc, renderBotList, tag } from "@research-ag/duel-game-core/render.js";

// The last bot this tab seated, and at which table: a Rematch there
// re-invites it. Per tab, like the session itself.
const LAST_BOT_KEY = "c4-last-bot";

const chip = (seat) => `<span class="c4-chip c4-chip-${seat}" aria-hidden="true"></span>`;

export function createBotChallenge({ actor, agent, backendId, client, plugin }) {
  const panel = document.getElementById("bot-challenge-panel");
  const body = document.getElementById("bot-challenge-body");
  const backend = Principal.fromText(backendId);

  let lastBot = load(); // { principalText, name, complexity, tableId }
  let pending = null; // the bot picked in the open dialog
  let staging = null; // this session's own waiting table: { tableId, openSeat, code }
  let reinvited = ""; // the reserved staging already re-invited, "table:gen"

  const label = (bot) => botDisplayName(bot.name, bot.complexity);

  function show(html) {
    panel.hidden = false;
    document.body.classList.add("bots-open");
    body.innerHTML = html;
  }

  function close() {
    panel.hidden = true;
    document.body.classList.remove("bots-open");
    pending = null;
  }

  const backToList = `<p><button type="button" class="ghost" data-bots-list>Back to the bots</button></p>`;

  async function showList() {
    pending = null;
    show(`<p class="muted">Looking for bots…</p>`);
    try {
      const bots = await actor.list_bots();
      if (panel.hidden || pending) return;
      const intro = staging
        ? `Pick a bot to take the open seat at your table.`
        : `Pick a bot and your colour; a table opens for the two of you.`;
      body.innerHTML = `<p class="muted">${intro}</p>${renderBotList(bots, plugin)}`;
    } catch (err) {
      console.error(err);
      if (!panel.hidden) body.innerHTML = `<p class="error">Could not load the bots.</p>${backToList}`;
    }
  }

  function seatChoice(bot) {
    const seat = (s, note) => `
      <button type="button" class="seat c4-seat" data-challenge-seat="${s}">
        ${chip(s)}
        <span class="c4-seat-text">
          <span class="seat-label">Play ${esc(plugin.seatLabel(s))}</span>
          <span class="muted">${note}</span>
        </span>
      </button>`;
    return `
      <p>Your colour against <strong>${esc(label(bot))}</strong>:</p>
      <div class="seats">${seat("p1", "drops first")}${seat("p2", "drops second")}</div>
      ${backToList}`;
  }

  function choose(bot) {
    pending = bot;
    if (staging) void invite(bot, staging);
    else show(seatChoice(bot));
  }

  // A fresh open table with this session at `seat`, as `staging` describes one.
  async function newTable(seat) {
    const out = await client.createTable(seat);
    if (!out.ok) {
      throw new Error(out.reason === "rejected" ? out.message : "Could not open a table — try again.");
    }
    const at = atTableOf(out.view);
    const v = viewOf(out.view, "stagingYou");
    if (!at || !v) throw new Error("Could not open a table — try again.");
    return stagingOf(at.id, v);
  }

  async function invite(bot, table) {
    show(`<p class="muted">Inviting ${esc(label(bot))}…</p>`);
    try {
      const target = table ?? (await newTable(bot.seat));
      const botActor = Actor.createActor(buildBotPlayIdlFactory, { agent, canisterId: bot.principalText });
      let res;
      try {
        res = await botActor.play(backend, target.tableId, { [target.openSeat]: null }, target.code, bot.complexity);
      } catch (err) {
        console.error(err);
        throw new Error(`${label(bot)} did not answer. It may be out of cycles or gone — try another bot.`);
      }
      if ("err" in res) throw new Error(playErrText(res.err, bot));
      remember({ principalText: bot.principalText, name: bot.name, complexity: bot.complexity, tableId: target.tableId });
      client.refresh(); // the bot's join shows on the next poll anyway; this is sooner
      if (pending === bot) close();
    } catch (err) {
      if (pending === bot) show(`<p class="error">${esc(err?.message ?? String(err))}</p>${backToList}`);
    }
  }

  // The bot's own `play` result, in this game's words.
  function playErrText(err, bot) {
    switch (tag(err)) {
      case "tooManyTables":
        return `${label(bot)} is already playing ${err.tooManyTables.max} games. Try again in a minute, or pick another level.`;
      case "seatTaken":
        return "Someone took the open seat first.";
      case "reserved":
        return "That seat is held for your last opponent for now.";
      case "noSuchTable":
        return "Your table closed before the bot arrived.";
      default:
        return errText(err);
    }
  }

  // Tracks this session's waiting table off every status, and re-invites
  // the last bot once when a Rematch stages its reserved seat.
  function track(status) {
    if (status === null) return; // still connecting: nothing to forget yet
    if (!panel.hidden && viewOf(status, "inGame")) close(); // a game started: show it
    const at = atTableOf(status);
    if (lastBot && !(at && at.id === lastBot.tableId)) remember(null);
    const v = viewOf(status, "stagingYou");
    staging = v ? stagingOf(at.id, v) : null;
    if (!v || !v.reservedForPartner || !lastBot) return;
    const key = `${at.id}:${v.gen}`;
    if (key === reinvited) return;
    reinvited = key;
    const bot = { ...lastBot };
    pending = bot;
    void invite(bot, staging);
  }

  function remember(bot) {
    lastBot = bot;
    try {
      if (bot) sessionStorage.setItem(LAST_BOT_KEY, JSON.stringify({ ...bot, tableId: bot.tableId.toString() }));
      else sessionStorage.removeItem(LAST_BOT_KEY);
    } catch (_) {}
  }

  document.getElementById("screen").addEventListener("click", (ev) => {
    if (ev.target.closest?.("[data-open-bots]")) void showList();
  });
  document.getElementById("bot-challenge-back").addEventListener("click", close);
  body.addEventListener("click", (ev) => {
    const botBtn = ev.target.closest("[data-challenge-bot]");
    if (botBtn) {
      choose({
        principalText: botBtn.dataset.challengeBot,
        name: botBtn.dataset.botName || botBtn.dataset.challengeBot,
        complexity: botBtn.dataset.botComplexity || "",
      });
      return;
    }
    const seatBtn = ev.target.closest("[data-challenge-seat]");
    if (seatBtn && pending) {
      const bot = { ...pending, seat: seatBtn.dataset.challengeSeat };
      pending = bot;
      void invite(bot, null);
      return;
    }
    if (ev.target.closest("[data-bots-list]")) void showList();
  });
  window.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape" && !panel.hidden) close();
  });

  client.subscribe((state, prev) => {
    if (state.status !== prev.status) track(state.status);
  });
  track(client.getState().status);
}

// `stagingYou` as what `play` needs: the table, the seat left open, and
// the access code of a protected table.
function stagingOf(tableId, v) {
  return {
    tableId,
    openSeat: tag(v.seat) === "p1" ? "p2" : "p1",
    code: "code" in v.visibility ? [v.visibility.code] : [],
  };
}

function load() {
  try {
    const saved = JSON.parse(sessionStorage.getItem(LAST_BOT_KEY));
    return saved ? { ...saved, tableId: BigInt(saved.tableId) } : null;
  } catch (_) {
    return null;
  }
}
