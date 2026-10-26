/*
 * ضع Project URL و anon/publishable key من Supabase هنا.
 * لا تضع service_role key في ملفات الموقع مطلقًا.
 */
window.PRINT_SUPABASE_CONFIG = {
  url: 'https://dcuxoqssdtbqbyujddeo.supabase.co',
  anonKey: 'sb_publishable_hu1tukznoUKUCYaw_ShMgQ_Y6BEnHmw'
};

window.printCloudCache = { users: [], jobs: [] };

// مصدر الأسعار الوحيد في الواجهة: JavaScript، ولا يعتمد على print_price_tiers في Supabase.
window.PRINT_PRICES = Object.freeze({
  bw: Object.freeze({
    normal: Object.freeze({
      tiers: Object.freeze([9,19,49,99,199,Infinity]),
      prices: Object.freeze({
        A3: Object.freeze([20,20,16,14,12,10]),
        A4: Object.freeze([10,10,8,7,6,5]),
        A5: Object.freeze([5,5,4,3.5,3,2.5])
      })
    })
  }),
  color: Object.freeze({
    normal: Object.freeze({
      tiers: Object.freeze([9,24,49,99,199,Infinity]),
      prices: Object.freeze({
        A3: Object.freeze([60,50,40,36,30,30]),
        A4: Object.freeze([30,25,20,18,15,15]),
        A5: Object.freeze([20,15,12,10,8,8])
      })
    })
  }),
  photo: Object.freeze({
    'photo-medium': Object.freeze({
      tiers: Object.freeze([9,24,49,99,Infinity]),
      prices: Object.freeze({
        A3: Object.freeze([140,130,120,110,100]),
        A4: Object.freeze([70,65,60,55,50]),
        A5: Object.freeze([40,35,30,28,25])
      })
    }),
    'photo-good': Object.freeze({
      tiers: Object.freeze([9,24,49,99,Infinity]),
      prices: Object.freeze({
        A3: Object.freeze([240,220,200,180,160]),
        A4: Object.freeze([120,110,100,90,80]),
        A5: Object.freeze([70,65,55,50,40])
      })
    }),
    sticker: Object.freeze({
      tiers: Object.freeze([9,24,49,99,Infinity]),
      prices: Object.freeze({
        A3: Object.freeze([160,150,140,130,120]),
        A4: Object.freeze([80,75,70,65,60]),
        A5: Object.freeze([40,38,35,33,30])
      })
    })
  })
});

window.printImageCount = function(files){
  return (files||[]).filter(file =>
    String(file.type||'').startsWith('image/') ||
    /\.(jpe?g|png|gif|webp)$/i.test(file.name||'')
  ).length;
};

window.printPriceQuote = function(color,size,type,copies,files){
  if(!files?.length) return {available:false,reason:'no-files'};
  const imageCount=window.printImageCount(files);
  if(imageCount>0 && imageCount<files.length) return {available:false,reason:'mixed-files'};
  if(imageCount===0) return {available:true,priced:false,quantity:null,imageCount:0};

  const copiesCount=Math.max(1,Math.min(10000,Math.floor(Number(copies)||1)));
  const quantity=imageCount ? imageCount*copiesCount : copiesCount;
  const isPhoto=type!=='normal';
  if(isPhoto && color!=='color') return {available:false,reason:'combination-unpriced',quantity,imageCount};

  const table=type==='normal'
    ? window.PRINT_PRICES[color]?.normal
    : window.PRINT_PRICES.photo?.[type];
  const prices=table?.prices?.[size];
  if(!table || !prices) {
    return {available:false,reason:size==='A5'||size==='A3'||size==='A4'?'combination-unpriced':'size-unpriced',quantity,imageCount};
  }
  if(isPhoto && imageCount===0) return {available:false,reason:'paper-unpriced',quantity,imageCount};

  const tierIndex=table.tiers.findIndex(max=>quantity<=max);
  if(tierIndex<0 || prices[tierIndex]==null) return {available:false,reason:'combination-unpriced',quantity,imageCount};
  const unitPrice=Number(prices[tierIndex]);
  return {
    available:true,priced:true,quantity,imageCount,unitPrice,totalPrice:unitPrice*quantity,
    quantityLabel:imageCount?'ورقة مطبوعة (صورة واحدة لكل ورقة × النسخ)':'نسخة'
  };
};

// التوافق مع أي جزء قديم من الواجهة؛ لا يستدعي RPC ولا يثق بسعر خادمي.
window.printPriceMatches = function(quote,storedPrice){
  return Boolean(quote?.available && storedPrice &&
    Number(storedPrice.quantity)===quote.quantity &&
    Number(storedPrice.unit_price)===quote.unitPrice &&
    Number(storedPrice.total_price)===quote.totalPrice);
};

window.printSupabaseReady = (async () => {
  const { url, anonKey } = window.PRINT_SUPABASE_CONFIG;
  if (!url || url.includes('YOUR_PROJECT') || !anonKey || anonKey.includes('YOUR_SUPABASE')) return null;
  if (!window.supabase?.createClient) throw new Error('تعذر تحميل مكتبة Supabase');
  const client = window.supabase.createClient(url, anonKey, {
    global: { headers: { apikey: anonKey } },
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      storage: window.localStorage
    }
  });
  window.printSupabase = client;
  return client;
})();

window.printCloud = {
  async client(){
    const db = await window.printSupabaseReady;
    if (!db) throw new Error('أضف مفتاح Supabase العام في supabase-config.js أولًا');
    return db;
  },
  async customerSession(){
    const db = await this.client();
    let { data:{ session }, error } = await db.auth.getSession();
    if(error) throw error;
    if(!session){ const result=await db.auth.signInAnonymously(); if(result.error)throw result.error; session=result.data.session; }
    return { db, user:session.user };
  },
  async adminSession(email,password){
    const db=await this.client();
    const {data,error}=await db.auth.signInWithPassword({email,password});
    if(error)throw error;
    const check=await db.rpc('is_print_admin');
    if(check.error||check.data!==true){await db.auth.signOut();throw new Error('هذا الحساب غير مخوّل كمدير');}
    return {db,user:data.user};
  },
  async loadPricing(){
    // الأسعار محلية بالكامل؛ لا يوجد طلب إلى جدول print_price_tiers.
    return window.PRINT_PRICES;
  },
  async refreshAdmin(){
    const db=await this.client();
    const check=await db.rpc('is_print_admin');
    if(check.error||check.data!==true)throw new Error('سجّل الدخول بحساب الإدارة');
    const [us,js,fs]=await Promise.all([
      db.from('print_users').select('*').order('created_at',{ascending:false}),
      db.from('print_jobs').select('*').order('created_at',{ascending:false}),
      db.from('print_job_files').select('*')
    ]);
    if(us.error)throw us.error;if(js.error)throw js.error;if(fs.error)throw fs.error;
    const users=us.data.map(u=>({id:u.id,name:u.name,phone:u.phone,status:u.status,createdAt:Date.parse(u.created_at),approvedAt:u.approved_at?Date.parse(u.approved_at):null}));
    const byId=new Map(users.map(u=>[u.id,u]));
    const filesByJob=new Map();
    for(const f of fs.data){const list=filesByJob.get(f.job_id)||[];list.push({name:f.file_name,size:Number(f.byte_size),type:f.mime_type,path:f.object_path});filesByJob.set(f.job_id,list);}
    const jobs=js.data.map(j=>{const u=byId.get(j.user_id)||{};return {id:j.id,userId:j.user_id,userName:u.name||'',phone:u.phone||'',files:filesByJob.get(j.id)||[],fileName:(filesByJob.get(j.id)||[]).map(f=>f.name).join(', '),color:j.color,size:j.paper_size,type:j.paper_type,copies:j.copies,pricingQuantity:j.pricing_quantity===null?null:Number(j.pricing_quantity),unitPrice:j.unit_price===null?null:Number(j.unit_price),totalPrice:j.total_price===null?null:Number(j.total_price),notes:j.notes,status:j.status,createdAt:Date.parse(j.created_at),updatedAt:Date.parse(j.updated_at)}});
    const chargeRows=jobs.filter(job=>job.status==='done'&&job.totalPrice!==null).map(job=>({job_id:job.id,user_id:job.userId,amount:job.totalPrice}));
    if(chargeRows.length){const {error}=await db.from('print_job_charges').upsert(chargeRows,{onConflict:'job_id',ignoreDuplicates:true});if(error)throw error;}
    const {data:charges,error:chargeError}=await db.from('print_job_charges').select('user_id,amount');
    if(chargeError)throw chargeError;
    const totals=new Map();
    for(const charge of charges||[])totals.set(charge.user_id,(totals.get(charge.user_id)||0)+Number(charge.amount||0));
    for(const user of users)user.totalPrintCost=totals.get(user.id)||0;
    window.printCloudCache.users=users;
    window.printCloudCache.jobs=jobs;
    return {users,jobs};
  },
  async setUserStatus(id,status){
    const db=await this.client();const {error}=await db.from('print_users').update({status,approved_at:status==='approved'?new Date().toISOString():null}).eq('id',id);if(error)throw error;
  },
  async setJobStatus(id,status){
    const db=await this.client();const {error}=await db.from('print_jobs').update({status,updated_at:new Date().toISOString()}).eq('id',id);if(error)throw error;
  },
  async deleteJob(id){
    const db=await this.client();
    const check=await db.rpc('is_print_admin');
    if(check.error||check.data!==true)throw new Error('سجّل الدخول بحساب الإدارة');
    const {data:files,error:fileError}=await db.from('print_job_files').select('object_path').eq('job_id',id);
    if(fileError)throw fileError;
    const paths=(files||[]).map(file=>file.object_path).filter(Boolean);
    if(paths.length){const {error}=await db.storage.from('print-files').remove(paths);if(error)throw error;}
    const {error}=await db.from('print_jobs').delete().eq('id',id);
    if(error)throw error;
  },
  async signedFile(path){
    const db=await this.client();const {data,error}=await db.storage.from('print-files').createSignedUrl(path,300);if(error)throw error;return data.signedUrl;
  }
};
