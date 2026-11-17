const MAX_BODY_BYTES = 1024;
const VERSION_PATTERN = /^\d{1,3}\.\d{1,3}\.\d{1,3}$/;

function jsonResponse(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
    },
  });
}

async function readBodyWithLimit(request) {
  if (!request.body) return '';

  const reader = request.body.getReader();
  const chunks = [];
  let totalBytes = 0;

  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_BODY_BYTES) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return undefined;
  }
}

function isValidPayload(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return false;
  }

  // Reject extra properties so the client cannot inject arbitrary message text.
  const keys = Object.keys(value).sort();
  if (keys.join(',') !== 'application,event,version') return false;

  return value.event === 'app_started' &&
    value.application === 'LinkScanner' &&
    typeof value.version === 'string' &&
    VERSION_PATTERN.test(value.version);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === '/health' && request.method === 'GET') {
      return jsonResponse({ ok: true, service: 'LinkScanner notifier' });
    }

    if (url.pathname !== '/api/notify') {
      return jsonResponse({ ok: false, error: 'not_found' }, 404);
    }

    if (request.method !== 'POST') {
      return new Response(null, {
        status: 405,
        headers: { allow: 'POST', 'cache-control': 'no-store' },
      });
    }

    const contentType = request.headers.get('content-type') ?? '';
    const mediaType = contentType.split(';', 1)[0].trim().toLowerCase();
    if (mediaType !== 'application/json') {
      return jsonResponse({ ok: false, error: 'unsupported_media_type' }, 415);
    }

    const contentLengthHeader = request.headers.get('content-length');
    if (contentLengthHeader !== null) {
      const contentLength = Number(contentLengthHeader);
      if (!Number.isSafeInteger(contentLength) || contentLength < 0) {
        return jsonResponse({ ok: false, error: 'invalid_content_length' }, 400);
      }
      if (contentLength > MAX_BODY_BYTES) {
        return jsonResponse({ ok: false, error: 'payload_too_large' }, 413);
      }
    }

    if (!env.NOTIFY_RATE_LIMITER ||
        typeof env.NOTIFY_RATE_LIMITER.limit !== 'function') {
      return jsonResponse({ ok: false, error: 'service_unavailable' }, 503);
    }

    // Cloudflare supplies this header at its edge. It is used only as a
    // transient rate-limit key; this Worker does not persist or log the IP.
    const clientIp = request.headers.get('CF-Connecting-IP') ?? 'unknown';
    let limitResult;
    try {
      limitResult = await env.NOTIFY_RATE_LIMITER.limit({ key: clientIp });
    } catch {
      return jsonResponse({ ok: false, error: 'service_unavailable' }, 503);
    }

    if (!limitResult?.success) {
      return jsonResponse({ ok: false, error: 'rate_limited' }, 429);
    }

    let rawBody;
    try {
      rawBody = await readBodyWithLimit(request);
    } catch {
      return jsonResponse({ ok: false, error: 'invalid_body' }, 400);
    }

    if (rawBody === null) {
      return jsonResponse({ ok: false, error: 'payload_too_large' }, 413);
    }
    if (rawBody === undefined) {
      return jsonResponse({ ok: false, error: 'invalid_body' }, 400);
    }

    let payload;
    try {
      payload = JSON.parse(rawBody);
    } catch {
      return jsonResponse({ ok: false, error: 'invalid_json' }, 400);
    }

    if (!isValidPayload(payload)) {
      return jsonResponse({ ok: false, error: 'invalid_event' }, 400);
    }

    const token = env.TELEGRAM_BOT_TOKEN;
    const chatId = env.TELEGRAM_CHAT_ID;
    if (typeof token !== 'string' || token.length < 20 ||
        typeof chatId !== 'string' || chatId.length < 1) {
      return jsonResponse({ ok: false, error: 'service_unavailable' }, 503);
    }

    // Keep the message template server-controlled. No free-form client text
    // or browsing/device data is forwarded to Telegram.
    const message = [
      'LinkScanner: app started',
      `Version: ${payload.version}`,
      'Event: app_started',
    ].join('\n');

    let telegramResponse;
    try {
      telegramResponse = await fetch(
        `https://api.telegram.org/bot${token}/sendMessage`,
        {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            chat_id: chatId,
            text: message,
            disable_web_page_preview: true,
          }),
        },
      );
    } catch {
      return jsonResponse({ ok: false, error: 'upstream_unavailable' }, 502);
    }

    if (!telegramResponse.ok) {
      return jsonResponse({ ok: false, error: 'upstream_rejected' }, 502);
    }

    let telegramResult;
    try {
      telegramResult = await telegramResponse.json();
    } catch {
      return jsonResponse({ ok: false, error: 'upstream_invalid_response' }, 502);
    }

    if (telegramResult?.ok !== true) {
      return jsonResponse({ ok: false, error: 'upstream_rejected' }, 502);
    }

    return jsonResponse({ ok: true });
  },
};
