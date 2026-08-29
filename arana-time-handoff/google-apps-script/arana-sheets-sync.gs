/**
 * ARANA TIME — Google Apps Script รับข้อมูล backup แบบเรียลไทม์จาก Supabase
 *
 * ★ ทำเป็นโปรเจกต์ Apps Script ใหม่แยกต่างหาก ไม่ผูกกับ Sheet ผ่าน Extensions → Apps Script ★
 * เพราะไฟล์ Google Sheet เดิมอาจมีสคริปต์เดิม (เช่น onFormSubmit) ที่ทำงานอยู่กับ Google Form
 * เดิมที่ยังใช้งานจริง ถ้าไปเปิดผ่าน Extensions → Apps Script แล้วลบโค้ดเดิมทิ้ง อาจทำโค้ด/
 * ทริกเกอร์เดิมพังได้ — วิธีนี้เป็นคนละโปรเจกต์กันเลย การันตีว่าไม่ไปแตะของเดิมแม้แต่บรรทัดเดียว
 *
 * วิธีติดตั้ง (ทำครั้งเดียว):
 * 1. เปิด https://script.google.com → กด "New project" (ไม่ต้องเปิดผ่าน Sheet)
 * 2. ลบโค้ดเดิมในไฟล์ Code.gs (โปรเจกต์ใหม่ มีแค่โค้ดเปล่าๆ) แล้ววางโค้ดทั้งไฟล์นี้แทน
 * 3. เปลี่ยนค่า SHARED_SECRET ด้านล่างเป็นข้อความสุ่มของคุณเอง (ยาวๆ คาดเดายาก)
 *    แล้วจดค่านี้ไว้ ต้องเอาไปใส่ในหน้าตั้งค่าของแอป ARANA TIME ด้วย (ต้องตรงกันเป๊ะ)
 * 4. กด Deploy (มุมขวาบน) → New deployment
 *    - Select type: Web app
 *    - Description: ใส่อะไรก็ได้ เช่น "arana sync v1"
 *    - Execute as: Me
 *    - Who has access: Anyone
 *    กด Deploy → อนุญาตสิทธิ์ (Authorize access) ตามที่ Google ถาม — จะมีหน้าเตือน
 *    "Google hasn't verified this app" เพราะเป็นสคริปต์ที่คุณเขียนเอง กด Advanced → Go to
 *    (ชื่อโปรเจกต์) (unsafe) ได้ตามปกติ ปลอดภัย เพราะเป็นโค้ดของคุณเอง
 * 5. จะได้ "Web app URL" มา 1 อัน หน้าตาประมาณ
 *    https://script.google.com/macros/s/xxxxxxxx/exec
 *    เอา URL นี้ไปใส่ในหน้าตั้งค่าแอป ARANA TIME (ช่อง Google Sheets Web App URL)
 * 6. ถ้าแก้โค้ดไฟล์นี้ทีหลัง ต้องกด Deploy → Manage deployments → แก้ไข (ไอคอนดินสอ)
 *    → เปลี่ยน Version เป็น "New version" → Deploy ใหม่ทุกครั้ง (URL เดิมใช้ต่อได้ไม่ต้องเปลี่ยน)
 *
 * แท็บในชีทจะถูกสร้างอัตโนมัติตอนข้อมูลชุดแรกส่งเข้ามา ไม่ต้องสร้างเองล่วงหน้า
 */

// ★★★ แก้ค่านี้เป็นรหัสลับของคุณเอง ต้องตรงกับที่ตั้งไว้ในแอป ARANA TIME ★★★
const SHARED_SECRET = 'เปลี่ยนเป็นรหัสลับของคุณ';

// ★★★ ID ของไฟล์ Google Sheet ปลายทาง (จาก URL ของ Sheet ส่วน .../d/<ตรงนี้>/edit...) ★★★
const TARGET_SPREADSHEET_ID = '1jTaBqRc9GuUg2wDd4Zm7p_7b1aaJ5J69goo0yfXKAHw';

// ชื่อแท็บ + ลำดับคอลัมน์ของแต่ละรายงาน (ต้องตรงกับที่ฝั่ง Supabase ส่งมา)
const SHEET_SCHEMAS = {
  // โครงสร้าง A:T นี้ตั้งใจให้ตรงกับคอลัมน์ A:P ของชีทเดิมที่รับข้อมูลจาก Google Form
  // (ข้อมูลแจ้งลา(สาขา) ปี 69) เป๊ะๆ เพื่อให้เพิ่มเป็นอีก 1 แหล่งใน FILTER() ของสูตร
  // All_Data เดิมได้เลย โดยไม่ต้องย้ายข้อมูลเก่า — คอลัมน์ Q:T เป็นของใหม่ที่เพิ่มต่อท้าย
  // (แถวเก่าจะว่างเปล่าตรงนี้ ไม่กระทบสูตรเดิมที่อ่านแค่ A:P)
  leaves: {
    name: 'ขาดลา',
    headers: ['แจ้งก่อน (วัน)', 'เดือน', 'ประทับเวลา', 'ที่อยู่อีเมล', 'ชื่อ-นามสกุล', 'ชื่อเล่น', 'ร้าน/สาขา', 'ตำแหน่งงาน', 'ลาวันที่', 'ลาถึงวันที่', 'จำนวนวันที่ลา', 'ประเภทการลา', 'จำนวนชั่วโมง', 'ลาเป็นชั่วโมง เริ่มเวลา', 'ลาเป็นชั่วโมง ถึงเวลา', 'เหตุผลในการลา', 'สถานะ', 'วันที่ตัดสิน', 'leave_id', 'employee_id'],
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
    const ss = SpreadsheetApp.openById(TARGET_SPREADSHEET_ID);

    // โหมดที่ 2: ส่งรายงานสรุปทั้งเดือนมาจากหน้า "รายงาน" ในแอป (เขียนทับแท็บเดิมของเดือนนั้น)
    if (body.reports && body.reports.length) {
      const names = body.reports.map(function (r) { return writeReportSheet(ss, r); });
      return jsonOut({ ok: true, reports: names, syncedAt: new Date().toISOString() }, 200);
    }

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
//
// ★ กันข้อมูลซ้ำ (dedupe) ★ ทุกชีท คอลัมน์รองสุดท้าย (index = width-2) คือ leave_id/log_id/ot_id
// เสมอ — ใช้เป็น unique key เช็คก่อนว่าเคยบันทึกแถวนี้ไปแล้วหรือยัง ถ้าเคยแล้วข้ามไปเลย ไม่ต่อท้ายซ้ำ
// เป็นการ์ดชั้นสุดท้ายกันข้อมูลซ้ำในชีท ไม่ว่าฝั่ง Postgres จะส่ง batch เดิมมาซ้ำด้วยสาเหตุอะไรก็ตาม
// (เน็ตหลุดกลางทางแล้ว retry, กด sync ซ้อนกันถี่ๆ, cron ทับ manual trigger ฯลฯ)
function appendRows(sheet, rows, key) {
  const width = SHEET_SCHEMAS[key].headers.length;
  const idCol = width - 2; // 0-based index ของคอลัมน์ id (ดูคอมเมนต์ด้านบน)
  const lastRow = sheet.getLastRow();
  const existingIds = new Set();
  if (lastRow > 1) {
    const idValues = sheet.getRange(2, idCol + 1, lastRow - 1, 1).getValues();
    idValues.forEach(function (r) { if (r[0]) existingIds.add(String(r[0])); });
  }
  const values = [];
  rows.forEach(function (r) {
    const id = String(r[idCol] || '');
    if (id && existingIds.has(id)) return; // ข้ามแถวที่มี id นี้อยู่ในชีทแล้ว
    if (id) existingIds.add(id);
    const row = r.slice(0, width);
    while (row.length < width) row.push('');
    values.push(row);
  });
  if (!values.length) return;
  const startRow = sheet.getLastRow() + 1;
  sheet.getRange(startRow, 1, values.length, width).setValues(values);
}

// ★★★ ยูทิลิตี้ล้างข้อมูลซ้ำที่มีอยู่แล้วในชีท — รันเองครั้งเดียวจาก Apps Script editor เท่านั้น ★★★
// (ไม่ถูกเรียกจาก doPost/doGet ไม่กระทบการ sync อัตโนมัติเลย)
//
// วิธีรัน: เปิดโปรเจกต์นี้ที่ script.google.com → เลือกฟังก์ชัน dedupeAllSheets จาก dropdown
// ด้านบน (ข้าง Debug/Run) → กด Run (▶) → อนุญาตสิทธิ์ถ้าถาม → เช็ค Execution log ว่าลบไปกี่แถว
//
// ลอจิก: ไล่ทีละแท็บ (ขาดลา/มาสาย/OT/Log In-Out) เก็บแถวแรกสุดที่เจอ id (leave_id/log_id/ot_id)
// นั้นไว้ ถ้าเจอ id ซ้ำในแถวถัดๆ ไปให้ลบทิ้ง — ไม่แตะแถวที่ id ว่าง (กันเผลอลบข้อมูลเก่าก่อนมีระบบนี้)
function dedupeAllSheets() {
  const ss = SpreadsheetApp.openById(TARGET_SPREADSHEET_ID);
  const results = {};
  for (const key of Object.keys(SHEET_SCHEMAS)) {
    const schema = SHEET_SCHEMAS[key];
    const sheet = ss.getSheetByName(schema.name);
    if (!sheet) { results[schema.name] = 'ไม่พบแท็บนี้'; continue; }
    const idCol = schema.headers.length - 2;
    const lastRow = sheet.getLastRow();
    if (lastRow <= 1) { results[schema.name] = 0; continue; }
    const idValues = sheet.getRange(2, idCol + 1, lastRow - 1, 1).getValues();
    const seen = new Set();
    const rowsToDelete = [];
    idValues.forEach(function (r, i) {
      const id = String(r[0] || '');
      if (!id) return; // แถวไม่มี id (ข้อมูลเก่าก่อนมีระบบนี้) ไม่แตะ
      if (seen.has(id)) { rowsToDelete.push(2 + i); } else { seen.add(id); }
    });
    // ลบจากแถวล่างขึ้นบน กันเลขแถวเลื่อนระหว่างลบ
    rowsToDelete.sort(function (a, b) { return b - a; }).forEach(function (r) { sheet.deleteRow(r); });
    results[schema.name] = rowsToDelete.length;
  }
  Logger.log(JSON.stringify(results, null, 2));
  return results;
}

// เขียนรายงานสรุปรายเดือน 1 แท็บ — เขียนทับข้อมูลเดิมของแท็บนั้นทั้งหมด
//
// ★ ความปลอดภัย: จะเขียนทับได้เฉพาะแท็บที่สคริปต์นี้สร้างเองเท่านั้น (ดูจากหมายเหตุกำกับที่
// เซลล์ A1 ว่าเป็น ARANA_REPORT_MARK) ถ้าเจอแท็บชื่อซ้ำที่ "ไม่ใช่" ของสคริปต์นี้ (เช่นแท็บที่
// คุณทำเองไว้ก่อน) จะไม่แตะเลย แต่จะสร้างแท็บใหม่ต่อท้ายชื่อด้วย " (แอป)" แทน
// เพื่อกันข้อมูลเดิมที่ตั้งค่าไว้แล้วหายโดยไม่ตั้งใจ
const ARANA_REPORT_MARK = 'ARANA_REPORT';

function writeReportSheet(ss, rpt) {
  var name = rpt.name;
  var sheet = ss.getSheetByName(name);
  if (sheet) {
    var note = sheet.getRange(1, 1).getNote();
    if (note !== ARANA_REPORT_MARK) {
      name = name + ' (แอป)';
      sheet = ss.getSheetByName(name);
    }
  }
  if (!sheet) {
    sheet = ss.insertSheet(name);
  } else {
    sheet.clear();
  }
  var width = rpt.headers.length;
  sheet.getRange(1, 1, 1, width).setValues([rpt.headers]).setFontWeight('bold').setBackground('#FCE7F3');
  sheet.getRange(1, 1).setNote(ARANA_REPORT_MARK);
  if (rpt.rows.length) {
    var values = rpt.rows.map(function (r) {
      var row = r.slice(0, width);
      while (row.length < width) row.push('');
      return row;
    });
    sheet.getRange(2, 1, values.length, width).setValues(values);
  }
  sheet.setFrozenRows(1);
  sheet.setFrozenColumns(2);
  return name;
}

function jsonOut(obj, code) {
  const out = ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
  return out; // Apps Script ContentService ไม่รองรับ custom HTTP status code ตรงๆ ใส่ ok:false ในตัว body แทน
}
