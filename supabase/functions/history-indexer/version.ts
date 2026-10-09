// The indexer's version, recorded in every history_indexer_runs row: "dev" in the repository; the copy uploaded at
// deploy carries the merge commit's short git SHA, so a rollback can be confirmed from the run rows.
export const VERSION = "dev";
