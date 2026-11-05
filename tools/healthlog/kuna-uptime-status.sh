#!/bin/bash
# Live stability status for the Kuna camera, read from the health logger CSV.
# A "clean streak" = continuous time with NO drop (no down/pingonly row) and NO reboot
# (no uptime reset). Goal: survive GOAL_SECS with zero drops to call the fix good.
#
#   one-shot:  ./kuna-uptime-status.sh
#   live view: watch -n 15 ./kuna-uptime-status.sh
#   remote:    watch -n 15 "ssh treebeard ./kuna-uptime-status.sh"
CSV="${CSV:-/home/pi/kuna-health.csv}"
GOAL="${GOAL:-14400}"   # 4 hours

awk -F, -v goal="$GOAL" '
function epoch(ts){ gsub(/[-T:Z]/," ",ts); return mktime(ts) }
function fmt(s,  d,h,m){ d=int(s/86400);s%=86400;h=int(s/3600);s%=3600;m=int(s/60);s%=60;
  return (d?d"d ":"")(h?h"h ":"")(m?m"m ":"")s"s" }
NR==1{next}
{
  ts=$1; reach=$2; up=$4+0; e=epoch(ts); last_ts=ts; last_e=e; last_reach=reach
  brk=0
  if(reach!="ssh") brk=1
  else if(prev_up>0 && up>0 && up<prev_up) brk=1     # uptime went backwards = reboot
  if(brk){ cur_start=0; if(reach!="ssh"){last_drop=ts; drops++} }
  else { if(cur_start==0) cur_start=e; curlen=e-cur_start; if(curlen>maxlen){maxlen=curlen} }
  prev_up=(reach=="ssh")?up:0
  # count drops in the last hour
  if(reach!="ssh" && e>=last_e-3600) {}  # (recent-drop count done below in END via array not needed)
}
END{
  nowstreak = (last_reach=="ssh" && cur_start>0) ? (last_e-cur_start) : 0
  pct = (nowstreak*100.0)/goal; if(pct>100)pct=100
  bars=int(pct/5); bar=""; for(i=0;i<20;i++) bar=bar (i<bars?"#":"-")
  printf "Kuna stability  (goal: %s clean, zero drops)\n", fmt(goal)
  printf "-----------------------------------------------\n"
  printf "state now       : %s   (last sample %s)\n", (last_reach=="ssh"?"UP":"DOWN"), last_ts
  printf "current streak  : %s\n", fmt(nowstreak)
  printf "   progress 4h  : [%s] %.1f%%\n", bar, pct
  printf "longest streak  : %s\n", fmt(maxlen)
  printf "last drop       : %s   (total drops logged: %d)\n", (last_drop?last_drop:"none"), drops+0
  if(nowstreak>=goal) printf "\n*** GOAL MET: %s clean. Fix confirmed. ***\n", fmt(nowstreak)
}
' "$CSV"
