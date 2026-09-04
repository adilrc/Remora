import AppKit

let remoraApp = NSApplication.shared
let remoraDelegate = AppDelegate()
remoraApp.setActivationPolicy(.accessory)
remoraApp.delegate = remoraDelegate
remoraApp.run()
