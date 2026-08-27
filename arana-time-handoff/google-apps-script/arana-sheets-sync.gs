/**
 * ARANA TIME — Google Apps Script รับข้อมูล backup แบบเรียลไทม์จาก Supabase
 *
 * วิธีติดตั้ง (ทำครั้งเดียว):
 * 1. สร้าง Google Sheet เปล่า 1 ไฟล์ (ตั้งชื่ออะไรก็ได้ เช่น "ARANA TIME - Backup")
 * 2. เปิดเมนู Extensions → Apps Script
 * 3. ลบโค้ดเดิมในไฟล์ Code.gs ทั้งหมด แล้ววางโค้ดทั้งไฟล์นี้แทน
 * 4. เปลี่ยนค่า SHARED_SECRET ด้านล่างเป็นข้อความสุ่มของคุณเอง (ยาวๆ คาดเดายาก)
 *    แล้วจดค่านี้ไว้ ต้องเอาไปใส่ในหน้าตั้งค่าของแอป ARANA TIME ด้วย (ต้องตรงกันเป๊ะ)
 * 5. กด Deploy (มุมขวาบน) → New deployment
 *    - Select type: Web app
 *    - Description: ใส่อะไรก็ได้ เช่น "arana sync v1"
 *    - Execute as: Me
 *    - Who has access: Anyone
 *    กด Deploy → อนุญาตสิทธิ์ (Authorize access) ตามที่ Google ถาม
 * 6. จะได้ "Web app URL" มา 1 อัน หน้าตาประมาณ
 *    https://script.google.com/macros/s/xxxxxxxx/exec
 *    เอา URL นี้ไปใส่ในหน้าตั้งค่าแอป ARANA TIME (ช่อง Google Sheets Web App URL)
 * 7. ถ้าแก้โค้ดไฟล์นี้ทีหลัง ต้องกด Deploy → Manage deployments → แก้ไข (ไอคอนดินสอ)
 *    → เปลี่ยน Version เป็น "New version" → Deploy ใหม่ทุกครั้ง (URL เดิมใช้ต่อได้ไม่ต้องเปลี่ยน)
 *
 * แท็บในชีทจะถูกสร้างอัตโนมัติตอนข้อมูลชุดแรกส่งเข้ามา ไม่ต้องสร้างเองล่วงหน้า
 */

// ★★★ แก้ค่านี้เป็นรหัสลับของคุณเอง ต้องตรงกับที่ตั้งไว้ในแอป ARANA TIME ★★★
const SHARED_SECRET = 'เปลี่ยนเป็นรหัสลับของคุณ';

// ชื่อแท็บ + ลำดับคอลัมน์ของแต่ละรายงาน (ต้องตรงกับที่ฝั่ง Supabase ส่งมา)
const SHEET_SCHEMAS = {
  leaves: {
    name: 'ขาดลา',
    headers: ['วันที่ยื่น', 'ชื่อพนักงาน', 'สาขา', 'ประเภทการลา', 'วันที่เริ่ม', 'วันที่สิ้นสุด', 'ช่วงเวลา (ถ้าลาเป็นชั่วโมง)', 'จำนวน', 'เหตุผล', 'สถานะ', 'วันที่ตัดสิน', 'leave_id', 'employee_id'],
  },
  late: {
    name: 'มาสาย',
    headers: ['วันที่', 'เวลาที่สแกน', 'ชื่อพนักงาน', 'สาขา', 'นาทีที่สาย', 'log_id', 'employee_id'],
  },
  ot: {
    name: 'OT',
    headers: ['วันที่ยื่นคำขอ', 'ชื่อพนักงาน', 'สาขา', 'วันที่ทำ OT', 'เวลาเริ่ม', 'เวลาสิ้นสุด', 'จำนวนชั่วโมง', 'เหตุผล', 'วันที่อนุมัติ', 'ot_id', 'employee_id'],
  },
  logs_inout: {
    name: 'Log In-Out',
    headers: ['วันที่', 'เวลา', 'ชื่อพนักงาน', 'สาขา', 'ประเภท', 'นาทีที่สาย (ถ้ามี)', 'log_id', 'employee_id'],
  },
};

function doGet(e) {
  return ContentService.createTextOutput('ARANA TIME sync endpoint is alive').setMimeType(ContentService.MimeType.TEXT);
}

function doPost(e) {
  try {
    const body = JSON.parse(e.postData.contents);
    if (body.secret !== SHARED_SECRET) {
      return jsonOut({ ok: false, error: 'unauthorized' }, 401);
    }
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const counts = {};
    for (const key of Object.keys(SHEET_SCHEMAS)) {
      const rows = body[key];
      if (!rows || !rows.length) { counts[key] = 0; continue; }
      const sheet = getOrCreateSheet(ss, key);
      appendRows(sheet, rows, key);
      counts[key] = rows.length;
    }
    return jsonOut({ ok: true, counts, syncedAt: new Date().toISOString() }, 200);
  } catch (err) {
    return jsonOut({ ok: false, error: String(err) }, 500);
  }
}

function getOrCreateSheet(ss, key) {
  const schema = SHEET_SCHEMAS[key];
  let sheet = ss.getSheetByName(schema.name);
  if (!sheet) {
    sheet = ss.insertSheet(schema.name);
    sheet.appendRow(schema.headers);
    sheet.setFrozenRows(1);
    sheet.getRange(1, 1, 1, schema.headers.length).setFontWeight('bold').setBackground('#FCE7F3');
  }
  return sheet;
}

// rows ที่ส่งมาจาก Supabase เป็น array ของ array (ลำดับค่าตรงกับ headers อยู่แล้ว)
// เพื่อลดความซับซ้อนฝั่ง Postgres ไม่ต้องส่งเป็น object คีย์ชื่อคอลัมน์
function appendRows(sheet, rows, key) {
  const width = SHEET_SCHEMAS[key].headers.length;
  const startRow = sheet.getLastRow() + 1;
  const values = rows.map(r => {
    const row = r.slice(0, width);
    while (row.length < width) row.push('');
    return row;
  });
  sheet.getRange(startRow, 1, values.length, width).setValues(values);
}

function jsonOut(obj, code) {
  const out = ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
  return out; // Apps Script ContentService ไม่รองรับ custom HTTP status code ตรงๆ ใส่ ok:false ในตัว body แทน
}
