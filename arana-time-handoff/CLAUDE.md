# ARANA TIME — ระบบเข้า-ออกงานหลายสาขา (Arana Clinic)

> ไฟล์นี้คือบริบทโปรเจกต์ทั้งหมด อ่านให้จบก่อนแก้โค้ดใดๆ เขียนไว้เพื่อให้ทำงานต่อเนื่องจากที่เคยคุยกับ Claude (แชท) มาก่อนหน้านี้ โดยไม่ต้องถามข้อมูลซ้ำ

---

## 1. ภาพรวมโปรเจกต์

- **แอปเดียว**: `../teletest-arana-time.html` (อยู่ที่ root ของ repo หนึ่งระดับเหนือโฟลเดอร์นี้ — **ชื่อไฟล์จริงที่ deploy ใช้งานอยู่ ห้ามเปลี่ยนชื่อเด็ดขาด** เพราะ URL `https://arana-aesthetic.github.io/teletest-arana-time/teletest-arana-time.html` ถูก bookmark ไว้แล้ว) — vanilla JS, ไม่มี build step, ไม่มี framework, ฟอนต์ Prompt (หัวข้อ) + Sarabun (เนื้อหา) จาก Google Fonts
- **ใช้งานจริง**: HR แอปสำหรับพนักงานหลายสาขา — เช็กอิน/เอาท์ด้วยการสแกนใบหน้า (face-api.js), ยื่นใบลา, ขอ OT, ตรวจปิดแอร์/ความสะอาด/ความเรียบร้อยพนักงาน, แจ้งเตือนผ่าน Telegram, ระบบสิทธิ์ผู้บริหาร
- **ผู้ใช้งานจริง**: เจ้าของคลินิก (Kulwarin) สื่อสารเป็นภาษาไทย ส่งสเปคละเอียดพร้อมภาพหน้าจอ/ตัวอย่างข้อความเป๊ะๆ เสมอ

### Hosting & Deploy
- **โฮสต์ผ่าน GitHub Pages** (ไม่ใช่ Netlify แล้ว — เคยใช้ Netlify ตอนแรกแต่เปลี่ยนมาแล้ว)
- **วิธี deploy**: repo นี้อยู่ในเครื่องมือของ Claude Code แล้ว (มี git) — แก้ `../teletest-arana-time.html` แล้ว `git add`/`commit`/`push` ไปที่ `origin/main` ตรงๆ ได้เลย → GitHub Pages build อัตโนมัติ (30 วินาที–2 นาที) **ห้าม** สร้างสำเนาไฟล์แอปซ้ำไว้ในโฟลเดอร์นี้อีก (เคยเกิดปัญหาไฟล์สองชุดไม่ sync กันมาแล้ว) แก้ที่ไฟล์เดียวที่ root เท่านั้น
- git remote: `https://github.com/ARANA-aesthetic/teletest-arana-time.git`

### Backend
- **Supabase** (Postgres + REST API ผ่าน PostgREST, ไม่ใช้ Supabase client library — เรียก REST API ตรงๆ ด้วย `fetch`)
- **Project URL**: `https://zjrlttyhdfcdjdnrvega.supabase.co`
- **Anon key**: ฝังอยู่ในโค้ดแล้วที่ตัวแปร `SUPABASE_ANON_KEY` ต้นไฟล์ `teletest-arana-time.html` (ตั้งใจให้เป็น client-side key, ปลอดภัยเพราะพึ่ง RLS policy `for all using (true) with check (true)` แบบเปิดกว้าง — โปรเจกต์นี้ไม่ต้องการ auth ระดับ user เพราะพนักงาน login ด้วยระบบ PIN ของแอปเอง ไม่ใช่ Supabase Auth)
- **ทุกตารางใช้ RLS policy เปิด (`for all using (true) with check (true)`) ให้ anon role เข้าถึงได้เต็มที่** — เป็นการตัดสินใจออกแบบตั้งใจ ไม่ใช่บั๊ก

---

## 2. โครงสร้างไฟล์

```
../teletest-arana-time.html   ← ไฟล์แอปทั้งหมด (HTML+CSS+JS ในไฟล์เดียว, อยู่ที่ root ของ repo — ไฟล์ deploy จริง)
CLAUDE.md                     ← ไฟล์นี้ (บริบทโปรเจกต์)
sql/                          ← SQL migration ทั้งหมดที่เคย apply ไปแล้วบน Supabase จริง (ดูหัวข้อ 6)
```

ไฟล์ `teletest-arana-time.html` แบ่งเป็นส่วนใหญ่ๆ ตามลำดับในไฟล์:
1. `<style>` — CSS ทั้งหมด (design tokens ในหัวข้อ 8)
2. HTML markup — login view, employee view, admin view, modals/overlays (ท้ายไฟล์)
3. `<script>` ท้ายไฟล์ — logic ทั้งหมด ลำดับคร่าวๆ:
   - Supabase config + storage layer (`sbSelectAll`, `sbUpsertRow`, `sbDeleteRow`)
   - Row↔object mappers (snake_case DB → camelCase JS) ต่อตาราง
   - `loadDB()` / `saveDB()` / `save{Table}Row()` / `delete{Table}Row()`
   - Calendar popup date picker (`dateSelectHTML`, `getDateVal`, `setDateVal`, `wireDateChange`, `#globalCalPopup`)
   - Login flow (employee PIN, approver PIN, admin password, remember-device, remember-session)
   - Employee view functions (`render*Tab`, quick actions, camera/face scan)
   - Admin view functions (`render*` ต่อแท็บ, `switchATab`)
   - Telegram helpers (`tgSendMessage`, `tgSendPhoto`, `tgSendPhotoById`, `viewTelegramPhoto`)
   - `init()` ท้ายสุด — bootstrap แอปตอนโหลดหน้า

**วิธีแก้ไขไฟล์**: ใช้ `grep -n` หา pattern ก่อนเสมอ แล้วใช้ str_replace/edit tool แบบ targeted (ไฟล์ใหญ่ ~5,000+ บรรทัด อย่า rewrite ทั้งไฟล์) หลังแก้เสร็จทุกครั้ง **ต้อง verify syntax** ด้วย (รันจาก root ของ repo, **ไม่ใช้ python3** — เครื่องนี้ python3 เป็น Windows Store stub ใช้งานไม่ได้จริง ใช้ node แทน):
```bash
node -e "
const fs = require('fs');
const t = fs.readFileSync('teletest-arana-time.html', 'utf-8');
const m = t.match(/<script>([\s\S]*)<\/script>\s*<\/body>/);
fs.writeFileSync('extracted_check.js', m[1]);
"
node --check extracted_check.js && echo "SYNTAX OK"
rm -f extracted_check.js
```

---

## 3. โครงสร้างฐานข้อมูล (Supabase — ตารางจริง, column ชัดเจน ไม่ใช่ JSONB blob เดียว)

### `branches`
| column | type | หมายเหตุ |
|---|---|---|
| id | text PK | |
| name | text | |
| lat, lng, radius | float/int | geofence ศูนย์กลาง+รัศมี (เมตร) |
| chat_id_checkinout | text | ห้อง Telegram เช็กอิน-เอาท์ ของสาขานี้ |
| chat_id_facility | text | ห้อง Telegram ปิดแอร์/ความสะอาด/ความเรียบร้อย ของสาขานี้ |
| chat_id_leave_approval | text | ห้อง Telegram แจ้งผลอนุมัติใบลา ของสาขานี้ |
| weekly_off_days | int[] | วันหยุดประจำสัปดาห์ (0=อาทิตย์...6=เสาร์) ไม่ส่งแจ้งเตือนวันนี้ |
| ac_points | jsonb | `[{id,name}]` เรียงลำดับได้ (ปุ่มเลื่อน ▲▼ ในแอป) |
| cleaning_points | jsonb | เหมือน ac_points |

### `employees`
| column | หมายเหตุ |
|---|---|
| id, name, nickname, department, job_title, branch_id, start_date, shift_start, shift_end, email | ปกติ |
| pin | 4 หลัก null ได้ (พนักงานตั้งเองครั้งแรก login) |
| descriptor | jsonb — face-api.js face descriptor array |
| home_lat, home_lng | พิกัดบ้าน (สุ่มตรวจวันลาป่วย) |
| active | boolean default true — **false = ปิดการใช้งาน (deactivate แทนลบ)** ไม่โผล่ในดรอปดาวน์ login |
| **`department` ต้องเป็นค่า `"หน้าร้าน"` เป๊ะๆ** (ไม่ใช่ branch) ถึงจะต้องส่ง "ความเรียบร้อยพนักงาน" — ใช้ควบคุมทั้ง client-side quick action และ SQL `send_facility_missing_reminder()` |

### `approvers` — ระบบผู้บริหาร (แยกจาก employees)
| column | หมายเหตุ |
|---|---|
| id, name, pin | เหมือน employees pattern |
| role | `'owner'` \| `'hr'` \| `'manager'` **(ไม่มี `'director'` แล้ว — ถูกลบออกตามคำขอ user ทีหลัง)** |

### `logs` — ประวัติเข้า-ออกงาน + AC + CLEAN + GROOM (ตารางเดียวรวมทุกประเภท)
| column | หมายเหตุ |
|---|---|
| id, employee_id, type, time, branch_id | type ∈ `IN`,`OUT`,`AC`,`CLEAN`,`GROOM` |
| late_minutes | int, คำนวณตอนเช็กอิน |
| sent | boolean — ส่ง Telegram สำเร็จไหม |
| ac_point_id, clean_point_id | FK ไปยัง jsonb array ใน branches (ผูกด้วย id string ไม่ใช่ FK จริง) |
| leave_conflict | boolean — true ถ้าเช็กอิน IN ทั้งที่มีใบลาเต็มวันอนุมัติแล้ววันนั้น (เตือนข้อมูลไม่สอดคล้อง) |
| corrected | boolean — true ถ้าเป็นรูปที่ถูกแก้ไข/ส่งซ้ำ (สำหรับ AC/CLEAN) |

### `leaves`
มาตรฐาน + `evidence_file_id` (เก็บ Telegram `file_id` ของรูปแนบตอนยื่นลา เพื่อ reuse ส่งรูปซ้ำตอนอนุมัติโดยไม่ต้องอัปโหลดใหม่) + `evidence_sent` (boolean)

kind enum: `sick_cert`, `sick_nocert`, `personal_nodeduct`, `personal_deduct`, `traditional`, `vacation`, `hourly_sick`, `hourly_personal`, `maternity`

### `ot_requests`
มาตรฐาน + **`group_id`** (text, nullable) — ผูกคำขอ OT ที่ส่งพร้อมกันหลายคน (1 คำขอ → หลายแถว แถวละ 1 คน แต่ share group_id เดียวกัน) ใช้แสดงรวมกันเป็นก้อนในหน้าอนุมัติ + อนุมัติ/ปฏิเสธพร้อมกันทั้งกลุ่มได้

### `branch_transfers` — คำขอไปทำงานสาขาอื่น/นอกสถานที่
| column | หมายเหตุ |
|---|---|
| id, employee_id, branch_id, from_date, to_date, reason, status, requested_at, decided_at | |
| **`branch_id` อาจเป็นค่า `'offsite'`** (sentinel string ไม่ใช่ FK จริง) = ทำงานนอกสถานที่ ไม่ระบุสาขา (เช่น ออกไปหาลูกค้า) — ไม่มี FK constraint บน column นี้ ปลอดภัยที่จะเก็บค่า string ใดๆ |

### `audit_log`
`id, actor_name, actor_role, action, target_type, target_id, details, created_at` — เขียนผ่านฟังก์ชัน `logAudit()` ทุกครั้งที่มีการ ลบ/แก้ไข/อนุมัติ/ปฏิเสธ ที่สำคัญ ดูได้ที่หน้า ตั้งค่า → "ประวัติการแก้ไข/ลบ"

### `notifications`
in-app notification ของแต่ละพนักงาน (แยกจาก Telegram)

### `settings` (แถวเดียว id=1)
`central_token` (bot token กลาง ใช้ร่วมกันทุกห้อง), `central_chat_id` (เฉพาะ "ยื่นใบลารออนุมัติ"), `ot_chat_id` (ห้องกลางแยกสำหรับ OT ทั้งขอและอนุมัติ), `grace_minutes`, `admin_password`, `holidays` (jsonb array วันหยุดบริษัทแบบ one-off), `notify_types` (jsonb เปิด-ปิดแจ้งเตือนแต่ละประเภท), `telegram_rooms` (jsonb ห้องสำรองอนาคต ยังไม่ผูกใช้งานจริง)

### Foreign Keys — สำคัญมาก
ตาราง `leaves`, `logs`, `ot_requests`, `notifications`, `branch_transfers` มี FK ไปยัง `employees(id)` แบบ **`on delete set null`** (แก้ไขภายหลังจากที่พบว่าลบพนักงานถาวรไม่ได้เพราะติด FK constraint แบบ default) — เจตนาออกแบบคือ **ลบพนักงานถาวรได้ ประวัติเก่ายังอยู่ในระบบ แค่ employee_id ของแถวเก่ากลายเป็น null** (เรียกดูชื่อไม่ได้อีกแต่ไม่เสียข้อมูลสถิติ)

ถ้าจะเพิ่มตาราง/ฟีเจอร์ใหม่ที่มี `employee_id` FK **ต้องตั้ง `on delete set null` ตั้งแต่แรก** ไม่งั้นจะเจอบั๊กเดิมซ้ำ

---

## 4. ระบบสิทธิ์ผู้ใช้ (สำคัญ — มีการรีดีไซน์ใหญ่มาแล้ว 2 รอบ)

### หน้า Login — เหลือ 2 ปุ่มหลัก
1. **"พนักงาน"** — เลือกชื่อจาก dropdown (เฉพาะ `active !== false`) → ใส่ PIN (ตั้งเองรอบแรก, กรอกครั้งเดียวพอไม่ต้องยืนยันซ้ำ)
2. **"ผู้บริหาร"** — เลือกชื่อจาก `approvers` table → ใส่ PIN เหมือนกัน — **รวม Owner/HR/Manager ไว้ที่ปุ่มเดียวกัน** (เดิมเคยแยก "เจ้าของ/HR" เป็นปุ่มรหัสผ่านต่างหาก ภายหลังรวมเข้าด้วยกันตามคำขอ user)
3. มีลิงก์เล็กๆ ใต้หน้าเลือกชื่อผู้บริหาร: **"เข้าด้วยรหัสผ่านเจ้าของระบบแทน"** — fallback ไปใช้ `settings.admin_password` (default `admin1234`) สำหรับ bootstrap สร้างบัญชี HR คนแรก, `session.role = 'admin'`

### Permission tiers (ฟังก์ชันอยู่ใกล้ `enterAdminView`/`enterApproverView`)
```js
isAdminTier()       // admin (password) หรือ approver role owner/hr → true
canAccessSettings() // = isAdminTier()
canManageApprovers()// admin หรือ approver role hr เท่านั้น (เพิ่ม/ลบ/ตั้งตำแหน่งผู้บริหารคนอื่น)
canApproveLeave()   // isAdminTier() หรือ approver role manager
canApproveOt()      // = isAdminTier() เท่านั้น (ตัด director ออกแล้ว เดิม director อนุมัติ OT ได้)
```

### Remember device / session (localStorage — ปลอดภัยใช้ได้เพราะ deploy จริงนอก Claude sandbox แล้ว)
- `aranaLastLogin` — จำ {type, id} ล่าสุดที่ login สำเร็จ → เปิดแอปครั้งถัดไปข้ามหน้าเลือกชื่อ ไปหน้า PIN ตรงเลย (มีปุ่ม "‹ กลับ" เพื่อสลับคนอื่นได้ กดแล้วจะ forget)
- `aranaActiveSession` — จำ session ที่ login ค้างอยู่ → **แก้บั๊ก "refresh หน้าเว็บแล้วหลุดออกจากระบบ"** — `init()` เช็ค key นี้ก่อนเสมอ ถ้ามีและ target ยังมีอยู่จริง จะ auto-resume เข้า view ตรงเลยไม่ต้อง login ใหม่ ลบ key นี้ตอน logout เท่านั้น

---

## 5. ฟีเจอร์หลักที่ทำเสร็จแล้ว (ครบทุกกลุ่ม 1-4)

### หน้าตาแอป Admin (bottom nav 5 แท็บ)
`ภาพรวม` / `พนักงาน` (view-only + export CSV + ฟิลเตอร์สาขา) / `อนุมัติ` (ใบลา+OT กลุ่ม+ย้ายสาขา, ฟิลเตอร์สาขา+วันที่แยกจาก "ประวัติทั้งหมด" ที่ซ่อนจนกว่าจะกดค้นหา) / `ตรวจ` (สถานะห้อง/โซน/พนักงานรายวัน ฟิลเตอร์สาขา+วันที่) / `ตั้งค่า` (จัดการพนักงาน, จัดการบัญชีผู้บริหาร, audit log, import CSV ข้อมูลเก่า, สาขา+AC/cleaning points เลื่อนลำดับได้, วันหยุดบริษัท, Telegram config, notify types)

### หน้าภาพรวม (Overview) — ล่าสุด
Dropdown preset: **วันนี้ / สัปดาห์นี้ / เดือนนี้ / เลือกช่วงเวลา** (เลือกอันสุดท้ายค่อยโชว์ปฏิทิน custom 2 ช่อง) — ฟังก์ชัน `applyOverviewPreset()`
- ถ้าเลือกช่วงมากกว่า 1 วัน (isRange) สถิติจะโชว์เป็น **"X ครั้ง"** (นับซ้ำได้) แทนสัดส่วน "X/Y คน" และซ่อนสถิติที่ไม่เกี่ยวกับช่วงเวลา (แจ้งปิดแอร์/ความสะอาด/ความเรียบร้อย → แสดง "-")

### ระบบวันที่ — ปฏิทินป๊อปอัพจริงทั้งระบบ
เดิมเป็น dropdown วัน/เดือน/ปี 3 ช่อง → **เปลี่ยนเป็นปฏิทินป๊อปอัพ (`#globalCalPopup`)** โดยคง public API เดิม (`dateSelectHTML(prefix, yearsBack, yearsForward)`, `getDateVal(prefix)`, `setDateVal(prefix, iso)`, `wireDateChange(prefix, cb)`) ทำให้ **ทุกจุดที่เรียกใช้ฟังก์ชันนี้อัปเกรดอัตโนมัติไม่ต้องแก้ทีละจุด** — สำคัญมากถ้าจะเพิ่มช่องกรอกวันที่ใหม่ ให้เรียกใช้ 4 ฟังก์ชันนี้เหมือนเดิม

### ฟีเจอร์ #27 — ทำงานสาขาอื่น/นอกสถานที่
พนักงาน → โปรไฟล์ → "ขอไปสาขาอื่น" → เลือก **สาขาจริง หรือ "ทำงานนอกสถานที่" (`branchId='offsite'`)** + ช่วงวันที่ + เหตุผล → รออนุมัติ (สิทธิ์เดียวกับใบลา)

วันที่อนุมัติแล้วและอยู่ในช่วง: **`currentBranch(emp)` จะ return สาขาที่ไปทำงานแทนสาขาต้นสังกัดอัตโนมัติ** (ฟังก์ชันนี้ถูกเรียกใช้แทบทุกจุด — geofence, Telegram routing, AC/Clean point list) ผลที่ตามมาอัตโนมัติ:
- เช็กอิน **ข้าม geofence GPS ทั้งหมด** (เช็คด้วย `isOnBranchTransferToday(emp)`)
- **ซ่อนเมนู AC (ปิดแอร์) + Cleaning (ความสะอาด)** ที่หน้าแรกพนักงาน (ให้พนักงานสาขานั้นดูแลแทน) — ความเรียบร้อยยังส่งได้ปกติ
- แจ้งเตือน Telegram (เช็กอิน/เอาท์/ความเรียบร้อย) ไปเข้าห้องของ**สาขาที่ไปทำงาน**อัตโนมัติ (หรือกลับสาขาต้นสังกัดถ้าเลือก offsite เพราะไม่มีห้องปลายทางจริง)
- ใช้ helper `transferTargetLabel(branchId)` แสดงชื่อ (จัดการ 'offsite' เป็น "ทำงานนอกสถานที่")

### ฟีเจอร์ #14 — Audit Log + แก้ไขรูปผิด + ยกเลิกสแกน
- `logAudit(action, targetType, targetId, details)` เรียกที่จุด: ลบพนักงาน/สาขา, ปิด-เปิดใช้งานพนักงาน, อนุมัติ/ปฏิเสธ ใบลา/OT/ย้ายสาขา, แก้ไขรูป AC/CLEAN, ยกเลิกสแกน, import CSV
- AC/Cleaning ที่ส่งแล้ว มีปุ่ม **"แก้ไขรูป"** แทน "แนบรูป" — resubmit แล้ว log entry เดิมถูกอัปเดต (ไม่สร้างแถวใหม่) + flag `corrected=true` + Telegram caption ขึ้น "♻️ (รูปแก้ไข)"
- หน้าแรกพนักงาน: ปุ่ม **"ยกเลิกรายการล่าสุด"** โผล่ถ้ามีสแกน IN/OUT ภายใน 15 นาทีที่ผ่านมา — ลบ log แถวนั้นได้เลย (ป้องกันเผลอสแกนผิด)

### ฟีเจอร์ #21 — Import ข้อมูลเก่า
ตั้งค่า → "นำเข้าข้อมูลเก่า" → อัปโหลด CSV รูปแบบ `วันที่(YYYY-MM-DD), ชื่อพนักงาน(ต้องตรงเป๊ะ), IN/OUT, เวลา, สายกี่นาที` → สร้างแถว `logs` ให้ **หมายเหตุ: เป็นฟอร์แมตทั่วไปที่ออกแบบเอง ยังไม่เคยได้ไฟล์จริงจาก user มาทดสอบ** ถ้า user ส่งไฟล์จริงมาที่มีรูปแบบต่าง ต้องปรับ parser ให้ตรง (ดูฟังก์ชัน `importAttendanceBtn` onclick handler)

### ฟีเจอร์ #29/30 — OT หลายคนพร้อมกัน
ฟอร์ม "ขอ OT" มี checklist พนักงานในสาขาเดียวกันให้ติ๊กหลายคน → สร้าง `ot_requests` 1 แถวต่อ 1 คน แต่ share `group_id` เดียวกัน → ข้อความ Telegram สรุปรวมคนตามแพทเทิร์นที่ user กำหนด (ดูตัวอย่างในโค้ด `submitOtBtn`/`decideOtGroup`) → หน้าอนุมัติจัดกลุ่มแสดงเป็นก้อนเดียว ปุ่ม "อนุมัติทั้งหมด/ปฏิเสธทั้งหมด" (`decideOtGroup`) → รายงาน/export ยังคงแยกรายคนอัตโนมัติเพราะเก็บคนละแถวอยู่แล้ว

### Responsive layout (#24)
เพิ่ม media query 2 breakpoint (≥640px, ≥1024px) เป็นการเพิ่มกฎ CSS **เสริมเท่านั้น ไม่ได้แก้ของเดิม** มือถือหน้าตาเหมือนเดิม 100%

### Telegram — ข้อความทั้งหมดปรับใหม่ตามตัวอย่างที่ user ให้ (#19)
- เช็กอิน/เช็กเอาท์, ส่งความเรียบร้อย, ส่งความสะอาด, ปิดแอร์ — จัดบรรทัดใหม่ (ดูใน `finalizeScan`, grooming/cleaning/AC input change handlers)
- **Telegram Bot API ไม่รองรับสีข้อความแบบกำหนดเอง** (ไม่มี `<font color>`) — ใช้ ⛔ emoji แทนสีแดงตามที่ user ขอไว้ (ต้องอธิบาย limitation นี้ให้ user ทราบถ้าถูกถามอีก)
- ดูรูปแนบใบลา — **เปิดเป็น popup ในแอป (`#photoViewOverlay`)** ไม่ใช่เปิดแท็บใหม่/ดาวน์โหลด (แก้ตามที่ user ขอภายหลัง) — ฟังก์ชัน `viewTelegramPhoto(fileId)` เรียก Telegram `getFile` API แล้วแสดง `<img>` ใน modal

### Business rules สำคัญ
- **สาย (late)**: `shiftLateMinutes(emp, now)` — ปกติคำนวณจาก `emp.shiftStart + grace_minutes` **แต่ถ้ามีใบลาแบบชั่วโมง (`hourly_sick`/`hourly_personal`) อนุมัติแล้ววันนั้น จะใช้ `hourEnd` ของใบลาเป็นฐานแทน shiftStart** (#17)
- **ขาด (absent)**: ไม่มี IN log + ไม่มีใบลาอนุมัติ + ไม่ใช่วันหยุด + ต้องเริ่มนับหลัง `employee.startDate`
- **เตือนข้อมูลไม่สอดคล้อง (#15)**: เช็กอิน IN ขณะมีใบลาเต็มวัน (ไม่ใช่ hourly) อนุมัติแล้ววันนั้น → ตั้ง `leaveConflict=true` + แจ้งเตือนพิเศษใน Telegram + แอป + หน้าตรวจ admin
- **แก้ไขใบลา (#13)**: พนักงานแก้ไขใบลาของตัวเองได้เฉพาะ `status==='pending'` เท่านั้น (`openLeaveForm(leaveId)` ใช้ทั้งสร้างใหม่และแก้ไข แยกด้วย `editingLeaveId`)

---

## 6. SQL Migration — ต้องรันให้ครบตามลำดับ (ทั้งหมดอยู่ใน `sql/`)

**สำคัญ**: user ยืนยันว่ารันไฟล์เหล่านี้ไปแล้วเกือบทั้งหมดจนถึง `fix-employee-delete-fk-v2.sql` (ล่าสุด) — **ให้ถือว่า schema ปัจจุบันของ Supabase ตรงกับผลลัพธ์ของการรันไฟล์ทั้งหมดนี้แล้ว** ไม่ต้องรันซ้ำเว้นแต่จะสงสัยว่ามีบางไฟล์ตกหล่น (ให้ถามผู้ใช้ก่อนถ้าจำเป็น)

ลำดับที่เคยรัน:
1. `telegram-rooms-migration.sql` — เพิ่ม 3 ห้อง Telegram แยกสาขา + evidence_file_id + telegram_rooms
2. `telegram-scheduled-reminders.sql` — สร้าง pg_cron functions ชุดแรก (leave summary, AC/facility reminder)
3. `telegram-grant-permissions.sql` — grant execute ให้ anon เรียกฟังก์ชันผ่าน RPC จากแอปได้
4. `telegram-reminder-fixes.sql` — เพิ่ม "ครบแล้ว✓" summary + กรอง department='หน้าร้าน'
5. `employee-active-column.sql` — คอลัมน์ `active` (deactivate)
6. `approvers-table.sql` — สร้างตาราง `approvers`
7. `group1-2-migration.sql` — `weekly_off_days`, `ot_chat_id`, ฟังก์ชัน `is_shop_closed()`, อัปเดต reminder ทั้ง 3 ให้ข้ามวันหยุด
8. `fix-employee-delete-permission.sql` — grant DELETE (เผื่อสิทธิ์)
9. `diagnose-maesot-notification.sql` — **สคริปต์ตรวจสอบเท่านั้น ไม่ใช่ migration** (ใช้ debug ปัญหาสาขาแม่สอดไม่ได้รับแจ้งเตือน — ยังไม่ได้ข้อสรุป ไม่กระทบงานอื่น เป็นปัญหาที่ค้างไว้เฉยๆ)
10. `group3-migration.sql` — `leave_conflict` column, สรุป 10:30 รวมมาสาย, ฟังก์ชันใหม่ `send_hourly_leave_checkin_summary()` (14:00) + cron ใหม่, wording ปิดแอร์/ความสะอาด แบบ "📍/▪️/⛔"
11. `branch-transfers-table.sql` — สร้างตาราง `branch_transfers`
12. `ot-group-column.sql` — คอลัมน์ `group_id` ใน `ot_requests`
13. `group4-migration.sql` — สร้างตาราง `audit_log` + คอลัมน์ `corrected` ใน `logs`
14. `fix-employee-delete-fk-v2.sql` — **ล่าสุด** ล้างข้อมูลกำพร้า + ตั้ง FK ทั้ง 5 ตาราง (leaves/logs/ot_requests/notifications/branch_transfers) เป็น `on delete set null`

**ไฟล์ที่ไม่ต้องใช้แล้ว**: `fix-employee-delete-fk.sql` (v1) ถูกแทนที่ด้วย v2 แล้ว (v1 พลาดขั้นตอนล้างข้อมูลกำพร้าก่อน ทำให้ error 23503) — ไม่ต้องรัน v1

### pg_cron schedule ที่ตั้งไว้ (เวลาไทย = UTC+7)
| เวลาไทย | UTC (cron) | ฟังก์ชัน |
|---|---|---|
| 10:30 | `30 3 * * *` | `send_daily_leave_summary()` — สรุปคนลา + คนมาสายวันนี้ |
| 11:30 | `30 4 * * *` | `send_facility_missing_reminder()` — เตือน/สรุปความสะอาด+ความเรียบร้อย |
| 14:00 | `0 7 * * *` | `send_hourly_leave_checkin_summary()` — เฉพาะวันมีคนลาชั่วโมง เช็กว่ากลับมาครบไหม |
| 23:00 | `0 16 * * *` | `send_ac_missing_reminder()` — เตือน/สรุปปิดแอร์ |

ทดสอบยิงจากแอปได้ที่ ตั้งค่า → "ทดสอบระบบแจ้งเตือนอัตโนมัติ" (เรียกผ่าน Supabase RPC `sbCallFunction()`)

---

## 7. ปัญหาที่ค้างอยู่ / ยังไม่จบ

1. **สาขาแม่สอดไม่ได้รับแจ้งเตือน 11:30 น.** — ให้ user รัน `diagnose-maesot-notification.sql` ไปแล้วแต่ยังไม่เคยได้ผลลัพธ์กลับมาดูจริงจัง (user ขอเลื่อนไปดูทีหลัง) ไม่กระทบฟีเจอร์อื่น เป็น edge case เดี่ยวๆ
2. **Import ข้อมูลเก่า (#21)** — ยังไม่เคยได้ไฟล์ CSV จริงจาก user มาทดสอบ format ที่ทำไว้เป็นการเดาแบบทั่วไป ต้องปรับถ้า user ส่งไฟล์จริงมา
3. **กลุ่ม 5 ยังไม่เริ่ม**: รายงาน Export สรุป Performance ประจำปี + ใช้ทำเงินเดือน — **รอไฟล์ตัวอย่างฟอร์มจาก user** ก่อนเริ่มออกแบบ อย่าเดาฟอร์แมตเอง ให้ถามก่อน

---

## 8. Design tokens (CSS variables ต้นไฟล์ `<style>`)
```css
--pink:#EC4899; --pink-dark:#DB2777; --pink-pale:#FCE7F3;
--bg:#FFF5F9; --card:#FFFFFF; --border:#F6DCEA; --text:#241827; --muted:#9CA3AF;
--green:#16A34A; --amber:#D97706; --red:#DC2626; --blue:#4F46E5;
```
ฟอนต์: Prompt (หัวข้อ), Sarabun (เนื้อหา) — **ห้ามใช้อิโมจิใน UI ของแอป** (ปุ่ม/label/ข้อความในแอป) แต่ **อนุญาตใช้อิโมจิในข้อความ Telegram ได้** (✅⛔📍▪️♻️ ตามตัวอย่างที่ user กำหนดเอง)

---

## 9. หลักการทำงานกับ user คนนี้ (สำคัญมาก อ่านก่อนเริ่มแก้อะไร)

1. **แก้เฉพาะจุดที่ user แจ้งเท่านั้น** — user ย้ำหลายรอบว่าห้ามแตะจุดอื่นที่ทำงานดีอยู่แล้ว เสี่ยงพังของเดิม ให้ `grep` หา pattern แบบ unique แล้วแก้แบบ targeted เท่านั้น ไม่ rewrite ทั้งฟังก์ชัน/ทั้งไฟล์โดยไม่จำเป็น
2. **ทุกครั้งที่แก้ต้อง verify syntax ด้วย `node --check`** ก่อนส่งมอบงาน (ดูคำสั่งในหัวข้อ 2)
3. **ทุกครั้งที่ต้องแก้ schema DB ให้สร้างไฟล์ SQL แยกเป็นไฟล์ใหม่** (ห้ามแก้ไฟล์ SQL เก่าที่รันไปแล้ว) ตั้งชื่อสื่อความหมาย อธิบายว่าต้องรันตอนไหน/ทำอะไร เป็นคอมเมนต์ภาษาไทยในไฟล์ SQL เอง
4. **user สื่อสารเป็นภาษาไทยเสมอ ให้ตอบเป็นภาษาไทย** ใช้โทนสุภาพเป็นกันเอง (ครับ/ค่ะ)
5. **ระวัง timezone bug**: การเทียบวันที่ระหว่าง string `"YYYY-MM-DD"` กับ `Date` object ต้องต่อ `T00:00:00` เสมอ (`new Date(dateStr+'T00:00:00')`) ไม่งั้นจะเพี้ยนเพราะ UTC parsing (ประเทศไทย UTC+7)
6. **ระวัง silent failure**: ทุกการเรียก Supabase REST (`fetch`) ต้องเช็ก `res.ok` แล้ว return `{ok, error}` เสมอ ห้าม catch แล้วเงียบ (เคยเป็นบั๊กใหญ่มาแล้วหลายรอบ)
7. **ทุกครั้งที่ปรับ UI ที่เกี่ยวกับวันที่ ให้เรียกใช้ระบบปฏิทินป๊อปอัพกลาง** (`dateSelectHTML`/`getDateVal`/`setDateVal`/`wireDateChange`) อย่าสร้างระบบเลือกวันที่ใหม่แยกเอง
8. งานที่ทำเสร็จแล้วทั้งหมด (กลุ่ม 1-4) **ผ่านการทดสอบจริงจาก user แล้วและใช้งานได้** — ตอนนี้อยู่ในโหมด bug-fix/polish ต่อเนื่องทีละจุดตามที่ user ทดสอบเจอ ไม่ใช่โหมดพัฒนาฟีเจอร์ใหญ่แล้ว (ยกเว้นกลุ่ม 5 ที่ยังไม่เริ่ม)
