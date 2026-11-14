// Ajan kullanıcıya metin göndermez, kod gönderir. Metni telefondaki uygulama seçili dile çevirir.
// Yanıt biçimi: { "error": { "code": "agent.auth.missingToken", "params": { ... } } }

export class AppError extends Error {
  readonly code: string;
  readonly status: number;
  readonly params: Record<string, unknown>;

  constructor(code: string, status = 400, params: Record<string, unknown> = {}) {
    super(code);
    this.code = code;
    this.status = status;
    this.params = params;
  }
}

export const notFound = (what: string, params: Record<string, unknown> = {}) =>
  new AppError(`agent.${what}.notFound`, 404, params);
