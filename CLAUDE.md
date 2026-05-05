# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Wonni is an AI-first marketplace iOS app built with SwiftUI. The app helps sellers and buyers transact quickly with features like intelligent camera-based listing creation, photo management, and a marketplace feed.

## Building and Running

This is an Xcode project. To build and run:

```bash
# Open the project in Xcode
open wonni/wonni.xcodeproj

# Or build from command line
cd wonni
xcodebuild -project wonni.xcodeproj -scheme wonni -destination 'platform=iOS Simulator,name=iPhone 15' build
```

The project requires:
- iOS 15 or higher
- Xcode with SwiftUI support
- Camera and Photo Library permissions for full functionality

## Architecture

### Data Flow Architecture

The app uses SwiftUI's environment object pattern for state management:

1. **ModelData** (`ModelData.swift`): Main data controller injected at app root in `wonniApp.swift`
   - Manages menu/listing data loaded from JSON (`Data/menu.json`)
   - Handles shared state like `searchText` across views
   - Currently uses mock data; intended migration path: Mock JSON → SwiftData → Firebase/Cloud

2. **Environment Object Propagation**: `ModelData` is injected in `wonniApp.swift` and accessed via `@EnvironmentObject` in child views

### View Structure

The app uses a tab-based navigation with 5 main sections:

- **MainView.swift**: Root TabView container with 5 tabs
  - Home: Feed of listings with search and featured carousels
  - Search: Dedicated search interface (shares `searchText` state with Home)
  - Sell: Camera-based listing creation
  - Inbox: Messages and notifications
  - Profile: User profile and settings

### Camera/Photo System Architecture

The Sell tab implements a sophisticated camera system with photo stacking (located in `Views/CameraView/`):

**Core Components:**
- **Camera.swift**: AVFoundation wrapper managing capture session, device switching, and photo capture
  - Provides `previewStream` (live viewfinder) and `photoStream` (captured photos) as AsyncStreams
  - Handles device orientation and authorization

- **DataModel.swift**: Camera data controller managing photo state
  - Maintains `sessionPhotos: [[UIImage]]` - a 2D array where each inner array is a "photo stack"
  - Photo stacks allow users to group related photos for a single listing
  - Provides methods: `addNewStack()`, `movePhotoWithinStack()`, `movePhotoBetweenStacks()`, `removePhoto()`
  - Handles async streams from Camera and converts to SwiftUI state

- **CameraView.swift**: Main camera UI
  - Uses `ViewfinderView` for live preview
  - Shows `PhotoStackView` - horizontal scroll of photo stacks above camera controls
  - Stack visualization: photos stagger diagonally (offset by 10pts each) for visual depth
  - Modal presentation (`PhotoStackModalView`) for editing stack contents
  - Flash animation implemented via `isFlashing` state (known bug: doesn't cover tab bar)

**Photo Stack Concept:**
Users can take multiple photos and organize them into "stacks". Each stack represents a set of photos for one listing or variation. The plus button creates a new empty stack. Tapping a stack opens a modal to rearrange/delete photos.

### Models

Located in `Models/`:
- **Menu.swift**: Defines `MenuSection` and `MenuItem` (currently used for mock marketplace items)
  - Note: `MenuItem` is temporary; proper models for `Listing`, `User`, `Message`, `Order`, etc. are planned but not yet implemented

- **Listing.swift, Order.swift**: Placeholder files (models not yet defined)

### Helper Utilities

- **Helper.swift**: Bundle extension with generic `decode<T: Decodable>()` method for loading JSON files into Swift models

## Development Workflow

### Adding New Views

1. Create view file in appropriate `Views/` subdirectory
2. If the view needs app-wide data, add `@EnvironmentObject var modelData: ModelData`
3. For camera-related views, ensure they work with the `DataModel` photo stack system

### Modifying Camera Features

The camera system has several interconnected components:
- Modify `Camera.swift` for capture logic changes
- Modify `DataModel.swift` for photo state management
- Modify `CameraView.swift` for UI changes
- Photo stacks are represented as `[[UIImage]]` - maintain this structure for compatibility

### Working with Mock Data

Currently using `Data/menu.json` loaded via `Bundle.decode()` helper. To modify:
1. Edit `Data/menu.json`
2. Update `ModelData.loadMenu()` if structure changes
3. Migration plan: Eventually replace with SwiftData persistence, then backend API calls

## Known Issues

From README.md unresolved bugs:
- **Screen flash animation**: White flash when taking photos doesn't cover the tab bar. The `isFlashing` state is local to CameraView. To fix, consider moving flash overlay to MainView or adjusting z-index.

## Current Development Status

From README.md features checklist:

**Completed:**
- ✅ Tabbed navigation (Home, Search, Sell, Inbox, Profile)
- ✅ Home view with search bar, carousel, and feed
- ✅ Search view with shared search state
- ✅ Camera view with gallery upload and photo capture
- ✅ Photo stacking system with scrollable view
- ✅ Plus button to create new photo stacks
- ✅ White flash animation on photo capture
- ✅ Portrait mode lock with proper photo orientation handling

**In Progress/Planned:**
- Photo stack modal with rearrangement (partially implemented - `PhotoStackModalView`)
- Navigation bar with back/forward buttons for camera flow
- Blank placeholder for new empty stacks
- Draft saving with SwiftData
- Full data model definitions (User, Listing, Message, Order, etc.)

The codebase shows heavy influence from Apple's "Capturing Photos" sample app (for camera functionality) and Hacking with Swift tutorials (for SwiftUI patterns and JSON decoding).
