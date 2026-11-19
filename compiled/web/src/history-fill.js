// How far the background fill of an inbox's history has come. The worker keeps this beside
// the database, in the same transaction as the rows it describes:
//
//   before   the oldest conversation fetched so far, as { created_at, id }
//   rows     how many records the fill has brought in
//   done     the beginning of history is here: every read is local
//   full     the fill stopped at its budget, and older mail stays on the server
//
// Everything newer than `before` is held without a gap, because the fill walks down from the
// newest conversation one page after another and the change feed keeps what it passed current.

// Older than any row. The first page asked for is the newest one.
export const START = { created_at: "9999-12-31T00:00:00.000000Z", id: "~" };

export const fresh = () => ({ before: START, rows: 0, done: false, full: false });

// Timestamps arrive in one fixed-width UTC form, so text order is time order.
const newer = (a, b) => a.created_at > b.created_at || (a.created_at === b.created_at && a.id > b.id);

// May a page of rows older than `before` be answered from the local database alone?
// Yes once the beginning is here, and yes where the page starts above the fill's own edge.
export function held(state, before) {
  if (!state) return false;
  if (state.done) return true;
  return !!before && state.before !== START && newer(before, state.before);
}

// The state after one page from the records endpoint. The cursor moves to the page's oldest
// conversation. Replies and marks ride along with their conversation and never move it.
export function advance(state, page, bytes, budget) {
  const records = Array.isArray(page.records) ? page.records : [];
  const last = records.filter(record => record.attributes?.kind === "message").at(-1);
  const done = page.has_more !== true;
  return {
    before: last ? { created_at: last.attributes.created_at, id: last.id } : state.before,
    rows: state.rows + records.length,
    done,
    full: !done && bytes > budget,
  };
}

export const query = (state, limit) => new URLSearchParams({
  type: "MailEntry", before_created_at: state.before.created_at, before_id: state.before.id, limit: String(limit),
}).toString();
