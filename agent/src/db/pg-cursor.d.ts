// Minimal typing of pg-cursor 2.x (the package ships none): only what db/pg.ts uses.
declare module "pg-cursor" {
  import type { FieldDef, Submittable } from "pg";
  interface CursorResult {
    fields: FieldDef[];
  }
  class Cursor implements Submittable {
    constructor(text: string, values?: unknown[] | null, config?: { rowMode?: "array"; types?: unknown });
    submit: Submittable["submit"];
    _result?: CursorResult;
    read(rows: number, cb: (err: Error | null, rows: unknown[][], result?: CursorResult) => void): void;
    close(): Promise<void>;
  }
  export default Cursor;
}
