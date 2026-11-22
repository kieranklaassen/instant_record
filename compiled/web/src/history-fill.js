// Generic background history-fill state machine for any model whose
// `sync_shape` declares `background_fill: true`. The worker persists this
// beside the SQLite snapshot in the same IndexedDB transaction as the rows:
//
//   type       model name (from the server's bootstrap `fill` descriptor)
//   partition  optional partition value
//   pageSize   rows per fill page
//   budget     byte cap past which the fill stops and leaves older rows on the server
//   before     the oldest root cursor fetched so far, as { created_at, id }
//   rows       how many records the fill has brought in
//   done       the beginning of history is here: every read is local
//   full       the fill stopped at its budget, and older rows stay on the server
//
// Everything newer than `before` is held without a gap, because the fill walks
// down from the newest root one page after another and the change feed keeps
// what it passed current.

// Older than any row. The first page asked for is the newest one.
export const START = { created_at: "9999-12-31T00:00:00.000000Z", id: "~" };

export const fresh = (descriptor = {}) => ({
  type: descriptor.type || "",
  partition: descriptor.partition || null,
  pageSize: descriptor.page_size || descriptor.pageSize || 200,
  budget: descriptor.budget_bytes || descriptor.budget || null,
  before: START,
  rows: 0,
  done: false,
  full: false,
});

// May a read be answered from the local database alone? Only once the beginning is here.
export const held = state => !!state && state.done === true;

// Advance state after one page from `/records`. Prefers the server's explicit
// `next_before` root cursor (so related rows riding along never skew the edge),
// falling back to the last record's `{ created_at, id }`.
export function advance(state, page, bytes, budget) {
  const records = Array.isArray(page.records) ? page.records : [];
  const cap = state.budget || budget;
  let nextBefore = state.before;
  if (page.next_before && page.next_before.created_at && page.next_before.id) {
    nextBefore = { created_at: page.next_before.created_at, id: page.next_before.id };
  } else if (records.length > 0) {
    const last = records.at(-1);
    if (last?.attributes?.created_at && last?.id) {
      nextBefore = { created_at: last.attributes.created_at, id: last.id };
    }
  }
  const done = page.has_more !== true;
  return {
    ...state,
    before: nextBefore,
    rows: state.rows + records.length,
    done,
    full: !done && !!cap && bytes > cap,
  };
}

export function query(state, limit = state.pageSize || 200) {
  const params = new URLSearchParams({
    before_created_at: state.before.created_at,
    before_id: state.before.id,
    limit: String(limit),
  });
  if (state.type) params.set("type", state.type);
  return params.toString();
}
