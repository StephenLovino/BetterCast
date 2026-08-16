That directory is purpose-built for this: MEMORY.md indexes every note with a one-line summary, and the individual files carry the detail.

For today specifically, point it at project_awdl_iphone_investigation.md, project_mac_signing_xcode27.md, and project_ios_rejection_v13.md.

Bash
IN
ls -lh ~/.claude/projects/-Volumes-macosexternal-Users-local-repo-hdd-BetterCast/*.jsonl 2>/dev/null | awk '{print $5, $NF}'

OUT
4.9M /Users/stephenlovino/.claude/projects/-Volumes-macosexternal-Users-local-repo-hdd-BetterCast/67eb2fc8-9206-4fb8-9e9b-5f9d0f0d16b6.jsonl
911K /Users/stephenlovino/.claude/projects/-Volumes-macosexternal-Users-local-repo-hdd-BetterCast/b13975ed-382b-4457-8af4-dd5cf5799123.jsonl
This session's transcript is 4.9 MB — too large to read wholesale, and full of tool output noise. Don't ask the other Claude to read it. The memory files carry the same conclusions in a few KB.

One thing worth doing before you reboot: the copy I made is a snapshot from a few minutes ago, so anything written after that won't be in it. Say the word before you go and I'll refresh it so nothing's stale.

For the release over there, the short version of what you need:

security find-identity -v -p codesigning → confirm Developer ID Application is present
Export it as .p12 while you're there, so you're never stuck again
Map the env vars, then build:

set -a; source .env; set +a
export APPLE_ID="$APPLE_ID_USER" APP_PASSWORD="$APPLE_APP_PASSWORD"
./make_app.sh
Version is already v16 in both make_app.sh and the plist
And the caution worth repeating: that build ships all 469 lines of uncommitted work in the tree, not just today's AWDL fixes. Some of it predates this session and I haven't reviewed or tested it.