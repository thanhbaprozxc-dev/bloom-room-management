const crypto = require('node:crypto');

function send(res, status, body) {
  res.status(status).setHeader('Cache-Control', 'no-store').json(body);
}

function authorized(req) {
  const expected = process.env.ADMIN_PASSWORD || '';
  const received = String(req.headers['x-admin-password'] || '');
  if (!expected || !received) return false;
  const a = Buffer.from(expected);
  const b = Buffer.from(received);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function validPeriod(value) {
  return /^\d{4}-(0[1-9]|1[0-2])$/.test(value || '');
}

function positiveNumber(value, field) {
  const result = Number(value);
  if (!Number.isFinite(result) || result < 0) {
    const error = new Error(`${field} phải là số không âm`);
    error.status = 400;
    throw error;
  }
  return result;
}

function billDto(row) {
  const start = Number(row.meter_start);
  const end = Number(row.meter_end);
  const rate = Number(row.electric_rate);
  const rent = Number(row.rent);
  const service = Number(row.service);
  const debt = Number(row.previous_debt);
  const usage = Math.max(0, end - start);
  const electric = usage * rate;
  const subtotal = rent + service + electric;
  return {
    id: row.id,
    period: row.period,
    room: row.room,
    rent,
    service,
    start,
    end,
    rate,
    usage,
    electric,
    subtotal,
    debt,
    payable: subtotal + debt,
    paid: Boolean(row.paid),
    updatedAt: row.updated_at
  };
}

async function supabase(path, options = {}) {
  const base = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!base || !key) {
    const error = new Error('Server chưa được cấu hình Supabase');
    error.status = 503;
    throw error;
  }
  const response = await fetch(`${base.replace(/\/$/, '')}/rest/v1/${path}`, {
    ...options,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
      ...(options.headers || {})
    }
  });
  const text = await response.text();
  const body = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const error = new Error(body?.message || body?.hint || 'Lỗi kết nối database');
    error.status = response.status;
    throw error;
  }
  return body;
}

module.exports = async function handler(req, res) {
  if (!authorized(req)) return send(res, 401, { error: 'Mật khẩu quản trị không đúng' });

  try {
    if (req.method === 'GET') {
      const period = String(req.query.period || '2026-09');
      if (!validPeriod(period)) return send(res, 400, { error: 'Kỳ phải có dạng YYYY-MM' });
      const rows = await supabase(`room_bills?period=eq.${encodeURIComponent(period)}&select=*&order=room.asc`);
      return send(res, 200, rows.map(billDto));
    }

    if (req.method === 'POST') {
      const body = typeof req.body === 'string' ? JSON.parse(req.body) : (req.body || {});
      const period = String(body.period || '2026-09');
      const room = String(body.room || '').trim();
      if (!validPeriod(period)) return send(res, 400, { error: 'Kỳ phải có dạng YYYY-MM' });
      if (!room || room.length > 30) return send(res, 400, { error: 'Số phòng không hợp lệ' });
      const record = {
        period,
        room,
        rent: positiveNumber(body.rent, 'Tiền thuê'),
        service: positiveNumber(body.service, 'Phí dịch vụ'),
        meter_start: positiveNumber(body.start, 'Điện đầu'),
        meter_end: positiveNumber(body.end, 'Điện cuối'),
        electric_rate: positiveNumber(body.rate || 4000, 'Đơn giá điện'),
        previous_debt: positiveNumber(body.debt, 'Nợ tháng trước'),
        paid: Boolean(body.paid),
        updated_at: new Date().toISOString()
      };
      if (record.meter_end < record.meter_start) return send(res, 400, { error: 'Điện cuối không được nhỏ hơn điện đầu' });
      const rows = await supabase('room_bills?on_conflict=period,room', {
        method: 'POST',
        headers: { Prefer: 'resolution=merge-duplicates,return=representation' },
        body: JSON.stringify(record)
      });
      return send(res, 200, billDto(rows[0]));
    }

    if (req.method === 'PATCH') {
      const id = Number(req.query.id);
      if (!Number.isInteger(id) || id < 1) return send(res, 400, { error: 'ID không hợp lệ' });
      const body = typeof req.body === 'string' ? JSON.parse(req.body) : (req.body || {});
      const rows = await supabase(`room_bills?id=eq.${id}`, {
        method: 'PATCH',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ paid: Boolean(body.paid), updated_at: new Date().toISOString() })
      });
      if (!rows.length) return send(res, 404, { error: 'Không tìm thấy hóa đơn' });
      return send(res, 200, billDto(rows[0]));
    }

    if (req.method === 'DELETE') {
      const id = Number(req.query.id);
      if (!Number.isInteger(id) || id < 1) return send(res, 400, { error: 'ID không hợp lệ' });
      await supabase(`room_bills?id=eq.${id}`, { method: 'DELETE' });
      return send(res, 200, { ok: true });
    }

    res.setHeader('Allow', 'GET, POST, PATCH, DELETE');
    return send(res, 405, { error: 'Phương thức không được hỗ trợ' });
  } catch (error) {
    console.error(error);
    return send(res, error.status || 500, { error: error.status ? error.message : 'Lỗi máy chủ' });
  }
};
