//
//  CPU_GuardApp.swift
//  CPU Guard
//
//  Created by Cenk Altı on 2021-11-13.
//

import os
import SwiftUI
import UserNotifications
import LaunchAtLogin

let cpuTreshold = 80.0
let memTreshold = 80
let allowedDuration = Int64(60e9) // nanoseconds
let interval = 5.0

var processes = [Int:MyProcess]() // keyed by pid
var mem = MyMemory()

let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "main")

@main
struct CPU_GuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusBarItem: NSStatusItem!
    var launchAtLoginMenuItem: NSMenuItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        runAutomaticallyAtStartup()
        createMenuBarItem()
        setupNotifications()
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true, block: self.tick)
    }
    
    func setupNotifications() {
        logger.log("requesting notification authorization")
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                logger.error("notification authorization error: \(error.localizedDescription)")
            }
            logger.log("notification authorization granted: \(granted)")
            if !granted {
                NSApplication.shared.terminate(self)
                return
            }
            
            // Clear notifications from previous launch
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            
            // Define the custom actions.
            let terminateAction = UNNotificationAction(
                identifier: "TERMINATE_ACTION",
                title: "Terminate",
                options: [.authenticationRequired, .destructive])
            let killAction = UNNotificationAction(
                identifier: "KILL_ACTION",
                title: "Kill",
                options: [.authenticationRequired, .destructive])
            
            // Define the notification type
            let cpuUsageCategory = UNNotificationCategory(
                identifier: "CPU_USAGE",
                actions: [terminateAction, killAction],
                intentIdentifiers: [])
            
            // Register the notification type.
            UNUserNotificationCenter.current().setNotificationCategories([cpuUsageCategory])
        }
    }
    
    func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            logger.error("Failed to find Activity Monitor")
        }
    }
    
    func createMenuBarItem() {
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusBarItem.button?.image = NSImage(named: "StatusIcon")
        self.statusBarItem.button?.image?.isTemplate = true
        self.statusBarItem.menu = NSMenu(title: "CPU Guard Status Bar Menu")
        launchAtLoginMenuItem = self.statusBarItem.menu?.addItem(withTitle: "Launch at login", action: #selector(handleLaunchAtLogin), keyEquivalent: "")
        if LaunchAtLogin.isEnabled {
            launchAtLoginMenuItem.state = .on
        }
        self.statusBarItem.menu?.addItem(withTitle: "Quit", action: #selector(handleQuitMenuItem), keyEquivalent: "")
    }
    
    @objc func handleLaunchAtLogin () {
        if launchAtLoginMenuItem.state == .off {
            LaunchAtLogin.isEnabled = true
            launchAtLoginMenuItem.state = .on
        } else {
            LaunchAtLogin.isEnabled = false
            launchAtLoginMenuItem.state = .off
        }
    }
    
    @objc func handleQuitMenuItem () {
        NSApplication.shared.terminate(self)
    }

    func runAutomaticallyAtStartup() {
        let key = "launchedBefore"
        let launchedBefore = UserDefaults.standard.bool(forKey: key)
        logger.log("application launched before: \(launchedBefore)")
        if !launchedBefore {
            logger.log("first launch, setting LaunchAtLogin = true")
            LaunchAtLogin.isEnabled = true
            UserDefaults.standard.set(true, forKey: key)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
           didReceive response: UNNotificationResponse,
           withCompletionHandler completionHandler:
             @escaping () -> Void) {
        
        logger.log("notification responce received: \(response.notification.request.identifier)")
        
        switch response.notification.request.identifier {
        case MyMemory.notificationRequestID:
            openActivityMonitor()
        default: // High CPU notification
            
            // Get the PID from the original notification.
            let pid = response.notification.request.content.userInfo["PID"] as! Int
            
            // Perform the task associated with the action.
            switch response.actionIdentifier {
            case "TERMINATE_ACTION":
                kill(pid_t(pid), SIGTERM)
                processes[pid] = nil
            case "KILL_ACTION":
                kill(pid_t(pid), SIGKILL)
                processes[pid] = nil
            default:
                logger.error("unknown notification action: \(response.actionIdentifier)")
            }
        }
        
        // Always call the completion handler when done.
        completionHandler()
    }
    
    func tick(timer: Timer) {
        let now = DispatchTime.now().uptimeNanoseconds
        
        // Run ps command
        let currentProcesses = runPs()
        
        // Check new processes
        for (pid, currentProcess) in currentProcesses {
            if let existingProcess = processes[pid] {
                // Update existing processes
                existingProcess.info = currentProcess
            } else {
                // Add new process
                processes[pid] = MyProcess(info: currentProcess)
            }
        }
        
        // Check existing processes
        for (pid, process) in processes {
            if currentProcesses[pid] == nil {
                // Remove stale process
                process.removeNotification()
                processes[pid] = nil
            } else if process.info.cpu < cpuTreshold {
                // CPU below treshold
                process.start = nil
                process.removeNotification()
            } else {
                // CPU above treshold
                logger.info("pid using too much cpu: \(pid)")
                if let start = process.start {
                    if (now - start) > allowedDuration {
                        process.deliverNotification()
                    }
                } else {
                    process.start = now
                }
            }
        }
        
        // Check memory pressure
        if let freeMemory = runMemoryPressure() {
            mem.usage = 100 - freeMemory
            logger.info("memory usage: \(mem.usage)")
            if mem.usage > memTreshold {
                mem.deliverNotification()
            } else {
                mem.removeNotification()
            }
        }
    }
    
}
