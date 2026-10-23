#!/bin/zsh
# Renders the hard dictation fixtures with macOS `say` (synthetic voices, no real recordings): 16 kHz mono 16-bit WAV.
# Each line: name | voice | what is said (say syntax: [[slnc N]] = N ms of silence) | the text that should be typed
# (\n = new line). Rewrites every clip and its .txt; vocabulary.json and terms.txt are kept by hand.
set -e
nl=$'\n'
cd "${0:A:h}"
while IFS='|' read -r name voice spoken typed; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  say -v "$voice" -o "$name.wav" --file-format=WAVE --data-format=LEI16@16000 "$spoken"
  print -rn -- "${typed//\\n/$nl}" > "$name.txt"
done <<'CLIPS'
01-caparo|Daniel|Under the Caparo test, the claimant has to show foreseeability, proximity, and that it is fair, just and reasonable to impose a duty of care.|Under the Caparo test, the claimant has to show foreseeability, proximity, and that it is fair, just and reasonable to impose a duty of care.
02-donoghue|Moira|In Donoghue versus Stevenson, Lord Atkin set out the neighbour principle in nineteen thirty two.|In Donoghue v Stevenson, Lord Atkin set out the neighbour principle in 1932.
03-latin|Daniel|Res ipsa loquitur can shift the evidential burden, but promissory estoppel is a shield, not a sword.|Res ipsa loquitur can shift the evidential burden, but promissory estoppel is a shield, not a sword.
04-pauses|Karen|So the main issue is [[slnc 1200]] whether the exclusion clause [[slnc 900]] passes the reasonableness test under the Unfair Contract Terms Act, nineteen seventy seven.|So the main issue is whether the exclusion clause passes the reasonableness test under the Unfair Contract Terms Act 1977.
05-psg|Daniel|Dembélé and Kvaratskhelia started up front for P S G, with Vitinha and João Neves behind them.|Dembélé and Kvaratskhelia started up front for PSG, with Vitinha and João Neves behind them.
06-tactics|Rishi|Their inverted full-back stepped into midfield, and the gegenpress won the ball back within six seconds. Their x G was two point four.|Their inverted full-back stepped into midfield, and the gegenpress won the ball back within 6 seconds. Their xG was 2.4.
07-fee|Daniel|The club paid fifty five million pounds, plus add-ons worth up to ten percent of the fee.|The club paid £55 million, plus add-ons worth up to 10% of the fee.
08-meeting|Samantha|Let's meet on Tuesday the fourteenth of March at three thirty P M.|Let's meet on Tuesday 14 March at 3:30pm.
09-list|Daniel|I need to do three things. [[slnc 500]] First, finish the tort essay. [[slnc 400]] Second, email the Kestrelco team. [[slnc 400]] Third, renew my railcard.|I need to do 3 things.\n1. Finish the tort essay.\n2. Email the Kestrelco team.\n3. Renew my railcard.
10-email|Moira|Send the draft to junior at kestrelco dot com and copy legal at u law dot ac dot uk.|Send the draft to junior@kestrelco.com and copy legal@ulaw.ac.uk.
11-url|Karen|The match report is on b b c dot co dot uk slash sport slash football.|The match report is on bbc.co.uk/sport/football.
12-commands|Daniel|Hi Jon comma new line thanks for the quick edit full stop new paragraph can you trim the intro by five seconds question mark|Hi Jon,\nThanks for the quick edit.\n\nCan you trim the intro by 5 seconds?
13-backtrack|Samantha|Book the pitch for seven, actually eight, on Friday.|Book the pitch for 8 on Friday.
14-name|Daniel|This is Junior Nkanabassi from Kestrelco, following up on the Ligue 1 graphics.|This is Junior Nkanabassi from Kestrelco, following up on the Ligue 1 graphics.
15-long|Rishi|Okay, um, I think the best way to answer this [[slnc 800]] is to start with the statute, [[slnc 600]] then the case law, and then apply it to the facts. [[slnc 1000]] Uh, the tricky part is remoteness under The Wagon Mound.|Okay, I think the best way to answer this is to start with the statute, then the case law, and then apply it to the facts. The tricky part is remoteness under The Wagon Mound.
16-kickoff|Flo (English (UK))|Kick-off is at eight P M, and their possession was sixty two percent in the first half.|Kick-off is at 8pm, and their possession was 62% in the first half.
CLIPS
