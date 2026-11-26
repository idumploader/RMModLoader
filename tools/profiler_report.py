#!/usr/bin/env python3
"""Print a native profiler recording; optionally create a standalone HTML report.

python3 tools/profiler_report.py mod_loader/profile-map.json --html /tmp/profile.html
No third-party Python modules or network resources are required.
"""

import argparse
import html
import json
from pathlib import Path


PAGE = r'''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>RGSS native profiler</title>
<style>
body{font:15px system-ui,sans-serif;background:#101722;color:#e5edf8;margin:32px}
h1{font-size:26px;margin-bottom:8px}p{color:#b9c7da;line-height:1.5}
input{padding:10px;width:min(500px,90%);background:#1c293b;color:inherit;border:1px solid #496280;border-radius:6px}
table{border-collapse:collapse;width:100%;font-size:13px;margin-top:20px}
th,td{text-align:right;padding:9px;border-bottom:1px solid #28374b;vertical-align:top}
th{cursor:pointer;position:sticky;top:0;background:#1c293b}
th:first-child,td:first-child{text-align:left}td:first-child{overflow-wrap:anywhere;max-width:500px}
small{display:block;color:#9eb2cd}canvas{width:100%;height:140px;background:#152132;border-radius:8px}
details{margin:20px 0;color:#e1c89e}button{cursor:pointer}#summary{font-size:17px}
</style>
<h1>RGSS native profiler</h1><p>__TITLE__</p><p id="summary"></p>
<details open><summary>Measurement limits and diagnostics</summary><ul id="limits"></ul></details>
<h2>Frame intervals</h2><p>Milliseconds between observed Graphics.update completions. First and last partial intervals are excluded. Includes rendering and waiting.</p>
<canvas id="chart" height="140"></canvas><p id="frames"></p>
<h2>Methods</h2><input id="filter" placeholder="Filter by method or script, e.g. BSMP">
<p>Click a column to sort. Self excludes nested calls. Total includes them; totals overlap. Recursive totals count each interval once per method. Times include profiling overhead.</p>
<table><thead><tr><th data-key="name">Method / first observed source</th><th data-key="self_ms">Self ms ↓</th><th data-key="total_ms">Total ms</th><th data-key="calls">Calls</th><th data-key="self_per_call">Self µs/call</th><th data-key="unwound">Unwound</th><th data-key="open_at_stop">Open at stop</th></tr></thead><tbody id="rows"></tbody></table>
<script id="data" type="application/json">__DATA__</script>
<script>
'use strict';
const data=JSON.parse(document.getElementById('data').textContent),meta=data.meta;
document.getElementById('summary').textContent=`${meta.duration_ms.toFixed(1)} ms recorded · ${meta.event_count.toLocaleString()} events · stop: ${meta.stop_reason}`;
for(const note of [...meta.limitations,`Callback time: ${meta.callback_ms.toFixed(2)} ms (not all tracing overhead). Unattributed: ${meta.unattributed_ms.toFixed(2)} ms. Unmatched returns: ${meta.unmatched_returns}. Exceptions: ${meta.raises}.`]){
 const li=document.createElement('li');li.textContent=note;document.getElementById('limits').append(li);
}
let sort='self_ms',descending=true;
for(const m of data.methods)m.self_per_call=m.calls?m.self_ms*1000/m.calls:0;
function render(){
 const query=document.getElementById('filter').value.toLowerCase();
 const methods=data.methods.filter(m=>(m.name+' '+m.file).toLowerCase().includes(query));
 methods.sort((a,b)=>{const x=a[sort],y=b[sort];return (typeof x==='string'?x.localeCompare(y):x-y)*(descending?-1:1);});
 const body=document.getElementById('rows');body.textContent='';
 for(const m of methods){
  const tr=document.createElement('tr'),name=document.createElement('td'),source=document.createElement('small');
  name.textContent=m.name+(m.native?' [native]':'');source.textContent=m.file?`${m.file}:${m.first_observed_line}`:'Source unavailable / native';name.append(source);tr.append(name);
  for(const key of ['self_ms','total_ms','calls','self_per_call','unwound','open_at_stop']){const td=document.createElement('td');td.textContent=['self_ms','total_ms','self_per_call'].includes(key)?m[key].toFixed(3):m[key].toLocaleString();tr.append(td);}
  body.append(tr);
 }
}
document.getElementById('filter').addEventListener('input',render);
for(const th of document.querySelectorAll('th'))th.addEventListener('click',()=>{descending=sort===th.dataset.key?!descending:true;sort=th.dataset.key;render();});
const frames=data.frames.filter(f=>!f.partial),values=frames.map(f=>f.duration_ms),ordered=[...values].sort((a,b)=>a-b);
const percentile=q=>ordered.length?ordered[Math.min(ordered.length-1,Math.floor((ordered.length-1)*q))]:0;
document.getElementById('frames').textContent=values.length?`${values.length} complete intervals · median ${percentile(.5).toFixed(2)} ms · p95 ${percentile(.95).toFixed(2)} ms · max ${percentile(1).toFixed(2)} ms`:'No complete frame intervals in this recording.';
function chart(){
 const canvas=document.getElementById('chart');canvas.width=Math.max(1,Math.floor(canvas.clientWidth));const ctx=canvas.getContext('2d'),max=Math.max(16.67,percentile(1));
 ctx.clearRect(0,0,canvas.width,140);ctx.strokeStyle='#55718e';ctx.beginPath();const reference=130-16.67/max*115;ctx.moveTo(0,reference);ctx.lineTo(canvas.width,reference);ctx.stroke();ctx.fillStyle='#b9c7da';ctx.fillText('16.67 ms',8,Math.max(12,reference-4));
 ctx.strokeStyle='#70d6bd';ctx.beginPath();values.forEach((v,i)=>{const x=i/Math.max(1,values.length-1)*canvas.width,y=130-v/max*115;i?ctx.lineTo(x,y):ctx.moveTo(x,y);});ctx.stroke();
}
window.addEventListener('resize',chart);render();chart();
</script></html>'''


def load_report(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("meta", {}).get("schema") != "rgss-native-profiler-v1":
        raise ValueError("Unsupported profiler recording schema")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("--html", type=Path, help="Write standalone HTML (must not exist)")
    parser.add_argument("--top", type=int, default=25)
    parser.add_argument("--filter", default="", help="Filter method/script names")
    args = parser.parse_args()
    data = load_report(args.recording)
    meta = data["meta"]
    print("%.2f ms | %d events | %s" % (meta["duration_ms"], meta["event_count"], meta["stop_reason"]))
    print("    Self ms    Total ms      Calls  Method")
    methods = [m for m in data["methods"] if args.filter.lower() in (m["name"] + " " + m["file"]).lower()]
    for method in sorted(methods, key=lambda m: m["self_ms"], reverse=True)[:max(0, args.top)]:
        print("%11.3f %11.3f %10d  %s" % (method["self_ms"], method["total_ms"], method["calls"], method["name"]))
    print("Unattributed: %.3f ms; unmatched returns: %d" % (meta["unattributed_ms"], meta["unmatched_returns"]))
    for note in meta["limitations"]:
        print("- " + note)
    if args.html:
        # Raw events stay in JSON; avoid multiplying large traces in the HTML.
        report = {key: data[key] for key in ("meta", "methods", "frames")}
        payload = json.dumps(report, ensure_ascii=True).replace("<", "\\u003c")
        page = PAGE.replace("__TITLE__", html.escape(str(args.recording))).replace("__DATA__", payload)
        with args.html.open("x", encoding="utf-8") as output:
            output.write(page)
        print("HTML: " + str(args.html))


if __name__ == "__main__":
    main()
