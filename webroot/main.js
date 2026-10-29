(function(){
  "use strict";
  var HIGH_FILE="/data/adb/chargebypasscap/high";
  var CAPF="/sys/class/power_supply/battery/capacity";
  var CURF="/sys/class/power_supply/battery/current_now";
  var USBON="/sys/class/power_supply/usb/online";
  var HOLDING="/data/adb/chargebypasscap/holding";
  var OVERRIDE="/data/adb/chargebypasscap/override";

  function $(id){ return document.getElementById(id); }
  var slider=$("capSlider"), capVal=$("capVal"), resumeHint=$("resumeHint"),
      saveBtn=$("saveBtn"), stText=$("stText"), stSub=$("stSub"),
      stIcon=$("stIcon"), heroState=$("heroState"), toastEl=$("toast"),
      noBridge=$("nobridge");
  var savedHigh=80, dirty=false, dragging=false;

  function toast(m,ms){ if(!toastEl) return; toastEl.textContent=m;
    toastEl.classList.add("show");
    clearTimeout(toast._t); toast._t=setTimeout(function(){
      toastEl.classList.remove("show"); }, ms||2000); }

  // Root bridge (KernelSU / SukiSU / APatch / MMRL all inject `ksu.exec`).
  function ksuExec(cmd){
    return new Promise(function(resolve){
      if(typeof ksu==="undefined"||!ksu.exec){
        resolve({errno:-1,stdout:"",stderr:"no bridge"}); return;
      }
      var cb="__cb"+Date.now()+Math.floor(Math.random()*1e6);
      window[cb]=function(errno,stdout,stderr){
        delete window[cb]; resolve({errno:errno,stdout:stdout||"",stderr:stderr||""});
      };
      try{ ksu.exec(cmd,"{}",cb); }
      catch(e){ delete window[cb]; resolve({errno:-1,stdout:"",stderr:String(e)}); }
    });
  }
  function hasBridge(){ return typeof ksu!=="undefined"&&!!ksu.exec; }

  function paintCap(v){
    v=Math.max(50,Math.min(100,parseInt(v,10)||80));
    capVal.textContent=v;
    resumeHint.textContent="charging resumes at "+(v-2)+"%";
    if(!dragging&&document.activeElement!==slider) slider.value=v;
    var btns=document.querySelectorAll("#presets .preset");
    for(var i=0;i<btns.length;i++)
      btns[i].classList.toggle("on",parseInt(btns[i].getAttribute("data-v"),10)===v);
  }

  function paintStatus(o){
    var cap=o.cap, usb=o.usb, holding=o.holding, override=o.override, charging=o.charging;
    if(usb!=="1"){ stIcon.textContent="🔌"; stText.textContent="Unplugged";
      stSub.textContent="daemon idle — plug in to resume capping";
      heroState.textContent="Unplugged — cap armed at "+savedHigh+"%"; return; }
    if(override){ stIcon.textContent="🔓"; stText.textContent="Override till unplug ("+cap+"%)";
      stSub.textContent="charging to 100% — unplug to reset";
      heroState.textContent="Override active — charging past "+savedHigh+"%"; return; }
    if(holding){ stIcon.textContent="⛔"; stText.textContent="Bypass ON, holding "+cap+"%";
      stSub.textContent="phone running off the cable, battery resting";
      heroState.textContent="Holding "+cap+"% off the cable"; return; }
    if(charging){ stIcon.textContent="🔋"; stText.textContent="Charging "+cap+"%";
      stSub.textContent="cap engages at "+savedHigh+"%";
      heroState.textContent="Charging "+cap+"% — cap at "+savedHigh+"%"; return; }
    stIcon.textContent="⏸"; stText.textContent="Idle "+cap+"%";
    stSub.textContent="suspended by your own hand — left alone";
    heroState.textContent="Idle at "+cap+"%";
  }

  function parseState(out){
    var o={high:"",cap:"",cur:"",usb:"",holding:"0",override:"0"};
    out.split("\n").forEach(function(l){
      var i=l.indexOf("="); if(i<1) return;
      o[l.slice(0,i).trim()]=l.slice(i+1).trim();
    });
    return {
      high:parseInt(o.high,10)||80,
      cap:o.cap||"?",
      usb:o.usb||"0",
      holding:o.holding==="1",
      override:o.override==="1",
      charging:parseInt(o.cur,10)<-500000
    };
  }

  function readAll(){
    var cmd='echo "high=$(cat '+HIGH_FILE+' 2>/dev/null)";'
      +'echo "cap=$(cat '+CAPF+' 2>/dev/null)";'
      +'echo "cur=$(cat '+CURF+' 2>/dev/null)";'
      +'echo "usb=$(cat '+USBON+' 2>/dev/null)";'
      +'[ -f '+HOLDING+' ] && echo holding=1 || echo holding=0;'
      +'[ -f '+OVERRIDE+' ] && echo override=1 || echo override=0';
    return ksuExec(cmd).then(function(r){
      if(r.errno===-1) return null;
      return parseState(r.stdout||"");
    });
  }

  function refresh(){
    if(!hasBridge()){ noBridge.classList.add("show"); return; }
    readAll().then(function(s){
      if(!s) return;
      savedHigh=Math.max(50,Math.min(100,s.high||80));
      if(!dirty&&!dragging) paintCap(savedHigh);
      paintStatus({cap:s.cap,usb:s.usb,holding:s.holding,override:s.override,charging:s.charging});
      saveBtn.disabled=!dirty;
    });
  }

  slider.addEventListener("input",function(){
    dragging=true; dirty=(parseInt(slider.value,10)!==savedHigh);
    paintCap(slider.value);
    if(dragging) slider.value=capVal.textContent;
    saveBtn.disabled=!dirty;
  });
  slider.addEventListener("change",function(){ dragging=false; });

  document.querySelectorAll("#presets .preset").forEach(function(b){
    b.addEventListener("click",function(){
      slider.value=b.getAttribute("data-v");
      dirty=(parseInt(slider.value,10)!==savedHigh);
      paintCap(slider.value); saveBtn.disabled=!dirty;
    });
  });

  saveBtn.addEventListener("click",function(){
    var v=Math.max(50,Math.min(100,parseInt(slider.value,10)||80));
    saveBtn.disabled=true;
    ksuExec("echo "+v+" > "+HIGH_FILE+" && echo saved").then(function(r){
      if(/saved/.test(r.stdout||"")){
        savedHigh=v; dirty=false; dragging=false;
        paintCap(v); saveBtn.disabled=true;
        toast("Cap saved: bypass at "+v+"%, resume at "+(v-2)+"%");
        setTimeout(refresh,600);
      } else {
        saveBtn.disabled=false;
        toast("Save failed — bridge error");
      }
    });
  });

  // First paint: defaults instantly, then reconcile with live values.
  paintCap(savedHigh);
  refresh();
  setInterval(function(){ if(!dirty&&!dragging) refresh(); },5000);
})();
