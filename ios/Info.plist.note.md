# Info.plist

There is **no hand-written `Info.plist`** in this folder. XcodeGen generates
`ATCTranscribe/Info.plist` from the `targets.ATCTranscribe.info` block in
`project.yml` when you run `xcodegen generate` on the Mac. Edit `project.yml`, not
a plist. The generated plist is git-ignored.
