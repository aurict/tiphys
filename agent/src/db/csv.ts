// CSV for the database console's export (PLAN.md §13.2, D-2): RFC 4180 (CRLF, fields with , " CR LF quoted, quotes
// doubled) with a spreadsheet formula-injection guard: a text cell starting with = + - @ (or tab / CR) gets a leading
// ' so Excel/LibreOffice/Sheets show it as text. Plain numbers ("-12.5", numeric text from int8/numeric) are left as
// they are: they can't be formulas.

export type CsvValue = string | number | boolean | null;

const FORMULA_START = /^[=+\-@\t\r]/;
const NUMERIC = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;

export function csvCell(v: CsvValue): string {
  if (v === null) return "";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return String(v);
  let s = v;
  if (FORMULA_START.test(s) && !NUMERIC.test(s)) s = `'${s}`;
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export const csvLine = (values: CsvValue[]) => values.map(csvCell).join(",") + "\r\n";
