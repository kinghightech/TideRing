# Tide 🌊

Hey, I'm Aahish and this is Tide! an iOS app I built that talks to a cheap Oura-Ring-style smart ring over Bluetooth and turns the data it spits out into something actually useful and nice to look at. This is basically my baby project, I built like 95% of this myself and I wanted to write this readme in my own words instead of some generic AI sounding doc, so bare with me if the grammar isnt perfect lol.

## Why I even made this

So I got one of these knockoff smart rings off amazon (the kind that look like an Oura but cost like 1/10th the price) and the companion app that comes with it is honestly kinda garbage. Ugly UI, ads everywhere, and it barely shows you anything useful about your own data. I figured, I have an iPhone, I know a bit of Swift, why not just build my own app that connects directly to the ring over BLE and shows me my health stuff the way I actually want to see it. That snowballed into Tide.

The whole point of the app is: pair with the ring, pull raw sensor data off it (heart rate, blood oxygen, sleep, steps, stress, all that), store it locally on your phone (no cloud, no server, no company selling your sleep data to anyone), and present it in a clean, kind of "liquid glass" looking UI that doesnt feel like a spreadsheet.

## A quick honest note on the Bluetooth stuff

Ima be real with you reverse engineering a proprietary BLE protocol from a random ring company is NOT easy, the byte level packets these things send are basically undocumented gibberish unless you know exactly what your looking for. I did not want to spend 3 weeks sniffing bluetooth packets by hand so I used AI (Claude) pretty heavily to help me get the Bluetooth/CoreBluetooth wiring working, decode the frame formats, and get the ring's "JRing" protocol talking properly to my Swift code. I also leaned on an existing open source project called PulseLoop (by Saksham Bhutani, shoutout to him) which had already cracked a lot of the protocol — that part of the code is ported over and used under the CC BY 4.0 license, full credit to him for that groundwork (theres a Credits screen in app settings that says the same thing). But the rest    thhe app itself, all the views, the design, the data model, the games, the whole product  thats me, with AI as a coding assistant along the way like most people use nowadays. Just wanted to be transparent about that instead of pretending I hand wrote every single bluetooth byte parser lol, thats just not realistic for a solo highschool-ish project.

## What it actually does (the features)

- **Pairs with the ring over Bluetooth (CoreBluetooth)** — scans, connects, and auto-reconnects to your last known ring so you dont have to re-pair every time you open the app
- **Home screen ("Summary")** — shows your daily readiness score, heart rate, steps, calories, sleep and other highlights at a glance, forced into dark mode because it just looks better that way
- **Trends** — historical charts so you can actually see how your heart rate/sleep/steps/spo2 etc are trending over days and weeks, not just a random number with no context
- **Vitals view** — heart rate, blood oxygen, blood pressure, stress/HRV, temperature, all broken out individually so you can dig into one metric at a time
- **Sleep tracking** — the ring tracks your sleep stages and the app groups it into "nights" (matching how a real sleep app should group it, based on your wake time not just calendar days)
- **Activity tracking** — steps, distance, calories, both live "today so far" numbers and day-by-day history
- **Tide Camera** — lets you use the ring as a literal remote shutter button for your iPhone camera, tap the ring, it takes a photo. this one honestly might be my favorite feature
- **Mini games controlled by the ring** — yeah for real, I built a few actual games (a dino-runner clone, a flappy-bird style game, a rythm game called RipTide, and a space themed one called Nebula Drift) that you control by literally tapping the physical ring instead of the screen. Its a bit of a gimmick but its genuinely fun and shows off what the ring can do besides just health tracking
- **Onboarding flow** — walks you through pairing your ring and setting up your profile (name, age, height, weight, goals etc) the first time you open the app
- **Settings** — ring connection management, notification prefs, your personal info/goals, and a credits page giving proper attribution to the protocol source
- **Everything stored locally** — theres no backend, no account creation, no server anywhere. Your health data lives in a JSON file in the app's own sandboxed storage on your phone and thats it. I did this on purpose, I don't want to be responsible for hosting anyones biometric data on a server, and honestly local-first just makes more sense for something this personal

## Tech stack

Kept this pretty lean on purpose:

- **Swift 5** with strict concurrency turned on (so basically everything touching the UI/ring state has to run on the Main Actor, which sounds annoying but it actually saved me from a bunch of race condition bugs)
- **SwiftUI** for literally the entire UI, no UIKit views anywhere that I can remember
- **CoreBluetooth** for talking to the ring directly — no BLE wrapper libraries, just raw CoreBluetooth
- **No CocoaPods, no Swift Package Manager dependencies** — the whole thing is 100% vanilla Apple frameworks. This was a conscious choice, I didnt want a dependency breaking in 2 years and me having no idea why my app stopped compiling
- Custom fonts (a serif for headlines, a sans for body text) with fallbacks to system fonts if they fail to load
- iOS 26's newer `.glass` effect APIs for that "liquid glass" frosted look you see thru out the app
- Just a single JSON file for storage, no CoreData, no SQLite, nothing fancy. Simple is good here imo

Targets iOS 26.5+, single Xcode project, no backend, no external services, no analytics, no tracking. Runs on a physical iPhone (bluetooth doesnt really work right in the simulator so you kinda need a real device and a real ring to test the actual core feature, which was annoying during dev ngl)

## The design

I wanted this app to not look like every other generic "fitness tracker" app with the same boring cards and default SF fonts everywhere. So theres a whole custom design system in here (I call it "Tide Design" in the code) with:
- A cyan/blue accent palette that ties into the whole "tide/ocean/water" name and theme
- Glassy, frosted looking cards and buttons using the newer iOS glass APIs
- Custom serif font for big headline text, cause it just feels a little more premium than default san-serif everywhere
- Dark mode forced on the home screen specifically (I just think it looks better there, other screens follow whatever your phone is set to)

## Data & privacy

Since I get asked this a lot  no this app does not send your data anywhere. There is no backend. There is no analytics SDK. There is no "we may share your data with partners" clause because there are no partners, its just a JSON file sitting in your phone's Application Support folder that only this app can read. If you delete the app, the data is gone. If your phone breaks and you didnt back it up, the data is gone. Thats the tradeoff you get for nothing being collected on a server somewhere.

## Status

This is a personal project I actively work on, its not on the app store (yet, maybe one day) and its mainly built for my own ring and my own use, though the JRing protocol should work with similarly branded rings running the same firmware family. Theres no test suite yet, most testing has just been me manually wearing the ring and poking at the app, which isnt ideal but is what it is for a solo project like this right now.

## Copyright

This project is copyrighted and fully owned by me, Aahish. All rights reserved. You are not allowed to copy, reuse, redistribute, resell or repackage any part of this code, the design, the content or the concept without my direct written permission. If you take this project or any meaningfull portion of it and use it as your own, you are breaking copyright law and you can and will be sued for it. Basically dont copy my work. If you want to use something here, just ask me first.

(Note: the ported JRing protocol code specifically is used under CC BY 4.0 from the original PulseLoop project by Saksham Bhutani — see the in-app Credits screen — but everything else in this repo, the app itself, the UI, the design, the games, all of it, is my own work and covered by the copyright above.)
