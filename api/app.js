const crypto = require('node:crypto');

function reply(res,status,data){res.status(status).setHeader('Cache-Control','no-store').json(data)}
function safeEqual(a,b){const x=Buffer.from(String(a||'')),y=Buffer.from(String(b||''));return x.length===y.length&&crypto.timingSafeEqual(x,y)}
function role(req){const value=req.headers['x-admin-password'];if(safeEqual(value,process.env.ADMIN_PASSWORD))return'admin';if(process.env.VIEWER_PASSWORD&&safeEqual(value,process.env.VIEWER_PASSWORD))return'viewer';return null}
function body(req){return typeof req.body==='string'?JSON.parse(req.body||'{}'):(req.body||{})}
function required(obj,fields){for(const f of fields)if(obj[f]===undefined||obj[f]===null||obj[f]==='')throw Object.assign(new Error(`Thiếu trường ${f}`),{status:400})}
function number(v,name){const n=Number(v);if(!Number.isFinite(n)||n<0)throw Object.assign(new Error(`${name} không hợp lệ`),{status:400});return n}
async function db(path,options={}){const base=(process.env.SUPABASE_URL||'').replace(/\/rest\/v1\/?$/,'').replace(/\/$/,'');const key=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!base||!key)throw Object.assign(new Error('Chưa cấu hình Supabase'),{status:503});const r=await fetch(`${base}/rest/v1/${path}`,{...options,headers:{apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json',...(options.headers||{})}});const text=await r.text();let data=null;try{data=text?JSON.parse(text):null}catch{data={message:text}}if(!r.ok)throw Object.assign(new Error(data?.message||data?.hint||'Lỗi database'),{status:r.status});return data}
async function audit(action,type,id,details){try{await db('audit_logs',{method:'POST',body:JSON.stringify({action,entity_type:type,entity_id:String(id||''),details})})}catch(e){console.error('audit',e.message)}}
const maps={
 properties:{table:'properties',select:'*,property_settings(*),rooms(count)',order:'name.asc',required:['property_code','name'],allowed:['property_code','name','short_name','address','phone','owner_name','owner_phone','email','tax_code','total_floors','notes']},
 settings:{table:'property_settings',order:'created_at.asc',required:['property_id'],allowed:['property_id','electric_rate','water_rate','default_service_fee','billing_close_day','payment_due_day','bank_name','bank_bin','bank_account','bank_account_name','qr_template','invoice_note']},
 rooms:{table:'rooms',order:'room_number.asc',required:['property_id','room_number'],allowed:['property_id','room_number','floor','area','base_rent','status','notes']},
 tenants:{table:'tenants',order:'full_name.asc',required:['property_id','full_name'],allowed:['property_id','full_name','phone','email','nationality','identity_type','identity_number','date_of_birth','permanent_address','emergency_contact','notes']},
 leases:{table:'leases',select:'*,rooms(room_number),tenants!leases_representative_tenant_id_fkey(full_name,phone)',order:'end_date.asc',required:['property_id','room_id','start_date','end_date'],allowed:['property_id','room_id','representative_tenant_id','start_date','end_date','monthly_rent','deposit_amount','payment_due_day','status','ended_at','end_reason','deposit_refunded','notes']},
 visas:{table:'tenant_visas',select:'*,tenants(full_name,nationality,phone)',order:'expiry_date.asc',required:['property_id','tenant_id','expiry_date'],allowed:['property_id','tenant_id','visa_number','visa_type','issued_date','expiry_date','issuing_country','document_url','status','notes']},
 invoices:{table:'invoices',select:'*,monthly_room_records!inner(*,rooms(room_number),billing_periods(period),leases(tenants(full_name)))',order:'issued_at.desc',required:['record_id'],allowed:['record_id','invoice_number','issued_at','due_date','total_amount','paid_amount','status']}
};
function pick(input,fields){return Object.fromEntries(fields.filter(k=>input[k]!==undefined).map(k=>[k,input[k]]))}
function clean(row){const nullable=new Set(['representative_tenant_id','lease_id','date_of_birth','ended_at','issued_date','due_date']);const numeric=new Set(['floor','area','base_rent','total_floors','monthly_rent','deposit_amount','payment_due_day','deposit_refunded','electric_rate','water_rate','default_service_fee','billing_close_day']);for(const k of Object.keys(row))if(row[k]===''){if(nullable.has(k))row[k]=null;else if(numeric.has(k))delete row[k]}return row}
function days(date){return Math.ceil((new Date(`${date}T00:00:00`)-new Date(new Date().toISOString().slice(0,10)+'T00:00:00'))/86400000)}
function warning(d){return d<0?'expired':d<=7?'danger':d<=30?'urgent':d<=60?'warning':'safe'}

module.exports=async function handler(req,res){
 const userRole=role(req);if(!userRole)return reply(res,401,{error:'Mật khẩu không đúng'});
 try{
  const resource=String(req.query.resource||'dashboard');
  if(req.method!=='GET'&&userRole!=='admin')return reply(res,403,{error:'Tài khoản chỉ có quyền xem'});
  if(req.method==='GET'&&resource==='session')return reply(res,200,{role:userRole});
  if(req.method==='GET'&&resource==='dashboard'){
   const propertyId=String(req.query.property_id||'');const filter=propertyId?`property_id=eq.${encodeURIComponent(propertyId)}&`:'';
   const [rooms,leases,visas,invoices]=await Promise.all([db(`rooms?${filter}select=id,status`),db(`leases?${filter}status=eq.active&select=id,end_date`),db(`tenant_visas?${filter}status=eq.active&select=id,expiry_date`),db(`invoices?status=in.(unpaid,partial,overdue)&select=id,total_amount,paid_amount,monthly_room_records!inner(property_id)${propertyId?`&monthly_room_records.property_id=eq.${encodeURIComponent(propertyId)}`:''}`)]);
   return reply(res,200,{rooms:{total:rooms.length,occupied:rooms.filter(x=>x.status==='occupied').length,vacant:rooms.filter(x=>x.status==='vacant').length},debt:invoices.reduce((s,x)=>s+Number(x.total_amount)-Number(x.paid_amount),0),leaseWarnings:leases.map(x=>({...x,days:days(x.end_date),level:warning(days(x.end_date))})).filter(x=>x.days<=60),visaWarnings:visas.map(x=>({...x,days:days(x.expiry_date),level:warning(days(x.expiry_date))})).filter(x=>x.days<=60)});
  }
  if(resource==='properties'&&req.method==='POST'){
   const x=body(req);required(x,['property_code','name']);const cfg=maps.properties;const property=pick(x,cfg.allowed);property.property_code=String(property.property_code).trim().toUpperCase();
   if(property.total_floors==='')delete property.total_floors;const rows=await db('properties',{method:'POST',headers:{Prefer:'return=representation'},body:JSON.stringify(property)});const settingFields=maps.settings.allowed.filter(k=>k!=='property_id');const settings={...pick(x,settingFields),property_id:rows[0].id};for(const k of ['electric_rate','water_rate','default_service_fee','billing_close_day','payment_due_day'])if(settings[k]==='')delete settings[k];await db('property_settings',{method:'POST',body:JSON.stringify(settings)});await audit('create','properties',rows[0].id,{property_code:property.property_code,name:property.name});return reply(res,201,rows[0]);
  }
  if(resource==='properties'&&req.method==='PATCH'){
   const id=String(req.query.id||'');if(!id)throw Object.assign(new Error('Thiếu ID tòa nhà'),{status:400});const x=body(req);const property=pick(x,maps.properties.allowed);if(property.property_code)property.property_code=String(property.property_code).trim().toUpperCase();
   if(property.total_floors==='')delete property.total_floors;const rows=await db(`properties?id=eq.${encodeURIComponent(id)}`,{method:'PATCH',headers:{Prefer:'return=representation'},body:JSON.stringify(property)});if(!rows.length)throw Object.assign(new Error('Không tìm thấy tòa nhà'),{status:404});const settings=pick(x,maps.settings.allowed.filter(k=>k!=='property_id'));for(const k of ['electric_rate','water_rate','default_service_fee','billing_close_day','payment_due_day'])if(settings[k]==='')delete settings[k];if(Object.keys(settings).length)await db(`property_settings?property_id=eq.${encodeURIComponent(id)}`,{method:'PATCH',body:JSON.stringify(settings)});await audit('update','properties',id,{...property,...settings});return reply(res,200,rows[0]);
  }
  if(req.method==='GET'&&resource==='monthly'){
   const period=String(req.query.period||new Date().toISOString().slice(0,7));const propertyId=String(req.query.property_id||'');
   const rows=await db(`monthly_room_records?select=*,rooms(room_number),billing_periods!inner(period)&billing_periods.period=eq.${encodeURIComponent(period)}${propertyId?`&property_id=eq.${encodeURIComponent(propertyId)}`:''}&order=rooms(room_number).asc`);return reply(res,200,rows);
  }
  if(req.method==='POST'&&resource==='monthly'){
   const x=body(req);required(x,['property_id','period','room_id']);
   let periods=await db(`billing_periods?property_id=eq.${x.property_id}&period=eq.${x.period}&select=id`);if(!periods.length)periods=await db('billing_periods',{method:'POST',headers:{Prefer:'return=representation'},body:JSON.stringify({property_id:x.property_id,period:x.period})});
   const defaults=(await db(`property_settings?property_id=eq.${x.property_id}&select=electric_rate,water_rate,default_service_fee`))[0]||{};
   const rec={property_id:x.property_id,billing_period_id:periods[0].id,room_id:x.room_id,lease_id:x.lease_id||null,rent:number(x.rent||0,'Tiền thuê'),electric_start:number(x.electric_start||0,'Điện đầu'),electric_end:number(x.electric_end||0,'Điện cuối'),electric_rate:number(x.electric_rate??defaults.electric_rate??4000,'Giá điện'),water_start:number(x.water_start||0,'Nước đầu'),water_end:number(x.water_end||0,'Nước cuối'),water_rate:number(x.water_rate??defaults.water_rate??0,'Giá nước'),service_fee:number(x.service_fee??defaults.default_service_fee??0,'Dịch vụ'),other_fee:number(x.other_fee||0,'Phí khác'),discount:number(x.discount||0,'Giảm giá'),previous_debt:number(x.previous_debt||0,'Nợ cũ'),notes:x.notes||null};
   if(rec.electric_end<rec.electric_start||rec.water_end<rec.water_start)throw Object.assign(new Error('Chỉ số cuối không được nhỏ hơn chỉ số đầu'),{status:400});
   const rows=await db('monthly_room_records?on_conflict=billing_period_id,room_id',{method:'POST',headers:{Prefer:'resolution=merge-duplicates,return=representation'},body:JSON.stringify(rec)});await audit('upsert','monthly_record',rows[0].id,rec);return reply(res,200,rows[0]);
  }
  if(req.method==='POST'&&resource==='payments'){
   const x=body(req);required(x,['invoice_id','amount']);const payment={invoice_id:x.invoice_id,amount:number(x.amount,'Số tiền'),paid_at:x.paid_at||new Date().toISOString(),method:x.method||'transfer',reference:x.reference||null,notes:x.notes||null};
   const rows=await db('payments',{method:'POST',headers:{Prefer:'return=representation'},body:JSON.stringify(payment)});const inv=(await db(`invoices?id=eq.${x.invoice_id}&select=*`))[0];const paid=Number(inv.paid_amount)+payment.amount;await db(`invoices?id=eq.${x.invoice_id}`,{method:'PATCH',body:JSON.stringify({paid_amount:paid,status:paid>=Number(inv.total_amount)?'paid':'partial'})});await audit('create','payment',rows[0].id,payment);return reply(res,201,rows[0]);
  }
  if(req.method==='POST'&&resource==='generate-invoices'){
   const x=body(req);required(x,['property_id','period']);
   const records=await db(`monthly_room_records?property_id=eq.${encodeURIComponent(x.property_id)}&select=*,rooms(room_number),billing_periods!inner(period)&billing_periods.period=eq.${encodeURIComponent(x.period)}`);
   const created=[];
   for(const r of records){const electric=(Number(r.electric_end)-Number(r.electric_start))*Number(r.electric_rate);const water=(Number(r.water_end)-Number(r.water_start))*Number(r.water_rate);const total=Number(r.rent)+electric+water+Number(r.service_fee)+Number(r.other_fee)+Number(r.previous_debt)-Number(r.discount);const inv={record_id:r.id,invoice_number:`${x.period.replace('-','')}-${r.rooms.room_number}`,due_date:x.due_date||null,total_amount:Math.max(0,total),status:'unpaid'};const rows=await db('invoices?on_conflict=record_id',{method:'POST',headers:{Prefer:'resolution=merge-duplicates,return=representation'},body:JSON.stringify(inv)});created.push(rows[0])}
   await audit('generate','invoices',x.period,{count:created.length});return reply(res,200,{count:created.length});
  }
  const cfg=maps[resource];if(!cfg)return reply(res,404,{error:'Chức năng không tồn tại'});
  if(req.method==='GET'){const id=req.query.id?`id=eq.${encodeURIComponent(req.query.id)}&`:'';const propertyId=String(req.query.property_id||'');const direct=propertyId&&['rooms','tenants','leases','visas'].includes(resource)?`property_id=eq.${encodeURIComponent(propertyId)}&`:'';const nested=propertyId&&resource==='invoices'?`monthly_room_records.property_id=eq.${encodeURIComponent(propertyId)}&`:'';return reply(res,200,await db(`${cfg.table}?${id}${direct}${nested}select=${cfg.select||'*'}&order=${cfg.order}`))}
  if(req.method==='POST'){const x=body(req);required(x,cfg.required);const row=clean(pick(x,cfg.allowed));const rows=await db(cfg.table,{method:'POST',headers:{Prefer:'return=representation'},body:JSON.stringify(row)});await audit('create',resource,rows[0].id,row);return reply(res,201,rows[0])}
  if(req.method==='PATCH'){required(req.query,['id']);const row=clean(pick(body(req),cfg.allowed));const rows=await db(`${cfg.table}?id=eq.${encodeURIComponent(req.query.id)}`,{method:'PATCH',headers:{Prefer:'return=representation'},body:JSON.stringify(row)});await audit('update',resource,req.query.id,row);return reply(res,200,rows[0])}
  if(req.method==='DELETE'){required(req.query,['id']);try{const rows=await db(`${cfg.table}?id=eq.${encodeURIComponent(req.query.id)}`,{method:'DELETE',headers:{Prefer:'return=representation'}});if(!rows?.length)throw Object.assign(new Error('Không tìm thấy dữ liệu cần xóa'),{status:404});await audit('delete',resource,req.query.id,{deleted:rows[0]});return reply(res,200,{ok:true})}catch(e){if(resource==='properties'&&(e.status===409||/foreign key|violates/i.test(e.message)))throw Object.assign(new Error('Không thể xóa tòa nhà đang có phòng hoặc dữ liệu liên quan'),{status:409});throw e}}
  return reply(res,405,{error:'Phương thức không hỗ trợ'});
 }catch(e){console.error(e);return reply(res,e.status||500,{error:e.status?e.message:'Lỗi máy chủ'})}
};
