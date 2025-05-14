# Final Project - Wonni  
Date: 3/4/2025  
Author: Jerry Shi  
CNET ID: jerryshi  

## Description:  
Wonni is an AI first marketplace that helps sellers and buyers transact, fast. It's the way buying and selling online should be.    

## Learning Topics:  
SwiftUI  
SwiftData  
App Marketing  
UI/UX Design  
Project Management     

## Features Checklist:  
Mock Data -> Swift Data -> Firebase / Cloud
### 📝 Base Features:  
### Define Models  
❌ Item  
❌ Listing  
❌ User  
❌ Message  
❌ Order  
❌ Search  
❌ Category  
### Define SwiftUI Views
✅ On launch, the main view has a tabbed bar of 5 views: Home, Search, Sell, Inbox, & Profile  
✅ The home view consists of a search bar subview, a scrollable pageview of trending categories/items, and a feed of items, similar to the landmarks sample app. This feed is populated manually with a json and mock data.  
✅ Search view also implements search bar subview and search is shared as a state between home & search view (i.e. so users can change views in the middle of searching then resume).
❌ Search view also has saved searches subview and browse by categories list. Additional stretch feature of autocomplete with trending / suggested searches below.  
✅ The sell view consists of a camera view that has options to upload from gallery or take photos to start a listing.  
✅ When the user takes a photo, it creates a photo stack in a scrollable view.  
✅ The user can tap the "plus" button to create a new stack of photos in the scrollable view.  
❌ When the user adds a new stack in the scrollable view, a blank image is shown as a placeholder.  
❌ If the user taps a stack in the scrollable view, a modal pops up with all the saved photos. The user can tap and hold to rearrange photos (including between views) or tap an edit button select multiple buttons quickly.  
❌ Photos in the camera view will be saved to a state/environment. This allows for the photo taking user journey to be resumed easily in case the user accidentally exits out of the app or switches screens. (Optional: when switching screens, user will be prompted to "Save photo(s) as draft(s)?" with options of "Yes, every time" "yes" or "no".) (Also Optional: Don't save photos taken to photo library.)  
✅ When the user takes a photo, a custom animation flashes the screen white to reflect that a photo was taken.
❌ After the flash disappears, the photo taken fills up the screen, then shrinks down to photo stack size and moves to the associate stack location before disappearing.  
✅ The sell view stays in portrait mode but photos are correctly adjusted when taken in landscape, upside down, etc.  
❌ The sell view has a top navigation bar with "back arrow" button to go back to previous screen, "camera" "scanner" and "text" for input options in a switcher at the top, and a "forward arrow" button to move onto listing view.  
❌ Below this navigation bar, if the user has saved drafts (saved to device using Swift Data), there will be a pop-up "Open Draft(s) Folder" with an X button to dismiss.
❌ The photo picking view looks consistent with photos app.  
❌ In the photo picking view, the user can select photos and place them into photo stacks, just like in the camera view (will reuse this subview).  
❌ Selected photos will be greyed out with a check mark but they can be selected again for a new stack. (EDGE CASE) Users can also select the same photo twice for a stack (e.g. if they want to add the same photo multiple times for different variations). Whenever they do this, they will see a popup menu of "Do you want to add a duplicate photo to this stack?" or "Photo has already been added to another stack. Add to this stack as well?" and the options will be "Yes, and don't ask again this session" or "Yes" or "No".  
❌ After publishing their listing, users will be presented with a popup menu "Delete posted pictures?" with response options "Yes, every time", "Yes", or "No". (Optional: Default is to no save photos to camera roll when taking photos in app. After uploading photos, menu will still present.)  
❌ The inbox view consists of notifications & messages. Each subview has pill shaped quick filter buttons such as "unanswered", "buying", "selling", "price drop", etc.  
❌ The profile view consists of the user's profile picture, some quick stats, and a selling, buying, settings, & help center list of links.  
❌ The camera button in the search view allows a user to quickly identify products from the camera or the camera roll (similar to new listing view). The user can take a photo or upload a photo and instantly get a popup modal of likely products, with the title, price, and prediction ("Prices are rising" / "Prices are dropping" / "Prices are staying the same"). Users can quickly add the items to their wish list or drafts. The modal is a list of items with one row per item / one item per row. The user can swipe left to add to wishlight and left to add to drafts.  
❌ On the my listings view, users can organize their listings into "playlists" (similar to tiktok) that function like folders so they can organize their listings for themselves & shoppers (e.g. "k-pop merch > jungkook").  
❌ Update launch screen to include name of application, full name, and CNET ID.  
❌ Add a correctly sized app icon.  
### Populate JSON with Mock Data  

🌟 Stretch Features:  
❌ (Optional) Use if available logic to detect iOS version and use updated version if iOS is up to date. (Swift UI is iOS 15 or higher)  
❌ Tapping edit on a photo in photo picker brings up the system built in image editor.  
❌ The sell - camera view functionality makes a call to a backend to identify what items are in the picture.  
❌ On a listing view, the user can save listings to a list by tapping a heart button. By pressing and holding the button, a vertical menu of the user's lists will pop up. What list they move their finger to will be highlighted. When the gesture ends, it will be saved to the list that they had highlighted.  The default lists are "Wishlist" and "Drafts". The wishlist is a list of items that a user wants to buy. The drafts is a list of items a user wants to sell. (Is this gesture interaction unique and/or patentable?)  
❌ On a list view, users can swipe left or right on items in the list to either move them to the top of the list or remove them from the list entirely (similar to inbox apps). Users can also tap an edit button to edit the list in bulk (and add items to cart in bulk). Pressing and holding on an item in this view will allow users to select multiple items to add to cart or remove from list.  
❌ Implement adaptive layout for ipad / iphone, and dark / light mode (double thin white lines outlining product item looks good - less glaringly white)

Wishlist of Features:  
❌ (TOP Priority )After users post a listing, it is automatically posted to a corporate etsy/ebay/tiktok shop/amazon/etc. account using the relevant API's. It will be priced at the take home price the seller has set + platform fees + a commission fee. If it sells on the platform, users will be given the order / buyer information and their listing will be marked as sold / quantity updated on all platforms.  
❌ (TOP Priority) Integration with AliExpress API will allow trending items to automatically be populated into the app & other platforms. These items will be purchased in bulk (up to de extremis limits, currently $800) and tested for quality and stored in US for fast shipping.  
❌ (Advanced class) Integrate widgets for watched items (similar to tikpicks dashboard for events).  
❌ Allow offers for new likers only (i.e. whenever seller sends out offer, it needs to be 10% or less than current price, but don't notify past likers if it is the same or higher price as a previous offer)
❌ Add additional image styling using image fade out to show when scrollable views have content off the screen.  
❌ When typing in the search bar, the suggested searches will automatically update as the user types.  
❌ In the checkout view, users can save an item to a list and a collapsible list below the cart will allow users to easily add items from their lists to the cart. Pressing and holding on an item in this view will allow users to select multiple items to add to cart or remove from list. Perhaps the listview can be implemented as a subview of the checkout.    
❌ The home screen (and rest of app) populates using actual data from a backend.  
❌ Users can link their emails in order to automatically populate their drafts list with items they have purchased. From there they can list items with one tap.  
❌ Automatically scrape ebay/etsy/mercari/etc. for arbitrage opportunities by item.  
❌ Salvage cancelled orders by offering cancelled orders to other sellers that have item in stock.  
❌ Automatically monitor status of shipments using API calls to USPS, UPS, etc.  
❌ Implement community moderation system. Buyers/sellers who initiate disputes will have community memmbers view anonymized info and make recommendations for how to handle. Customer service agents will ultimately make final decision but the community moderation component helps ensure decisions are balanced for both sellers & buyers as well as cut down on fraud.  
❌ Integrate with Twilio or other service to send SMS for 2 factor authorization & urgent alerts (i.e. seller made sale, buyer requested cancellation, etc.).  
❌ Automatically show key stats on buyer & seller profiles - % on time shipment rate, % order defect rate vs. % return initiated rate, etc.
❌ Automatically scrape ebay/etsy/mercari/etc. for arbitrage opportunities by item.    
❌ Live selling w/ commission model for affiliates.  
❌ Short video selling w/ commission model for affiliates.  
❌ Create process / systems for content creation, similar to tiktokshop / duolingo for product & corporate advertisements.  
❌ Selling screen includes a trending page for sellers to find items to sell. E.g. "this popcorn bucket has sustained views, list now?" CTA, etc.  
❌ Systematize high likelihood to sell items that haven't been listed yet (i.e. popcorn buckets or tour merch).  
❌ Buyers can set an alert on out of stock / not yet in stock items to be alerted when they sell. They can also save searches to get alerts on similar items / broad categories (i.e. "kids hockey sticks listed for under $50"). Buyers can send offers on items, regardless of whether or not they are in stock, and offers are sent to all sellers / interested sellers and are binding for 24 hours.  
❌ Sellers who opt in can receive location based alerts for trending items. For example, if a seller goes by a movie theater, they might receive an alert for what popcorn buckets are trending. If a seller is at a concert venue the night of a concert, they could receive alerts for what merch items are trending from that concert. Possibility to expand here to a doordash like service (i.e. special debit/credit card that will be authorized to a certain amount for sellers to get cash to buy items and sellers get a flat fee / commission instead of all profits).  
❌ Engage beta testers, online sellers / buyers, etc. to help formulate balanced policies for marketplace. Tentative policies: Buyer has 7 days after delivery to raise any issues / request refund. If seller shipped within 3 business days, they will get an automatic 5 star review if buyer does not rate. If seller cancels within 3 business days of order, they will receive an automatic note on their profile but no marks to their status (since order is still salvageable) and buyer can NOT review. Platform has 48 hours after cancellation to find substitute seller before order is automatically cancelled. If seller cancels after 3 business days of order, they will still receive an automatic note on their profile, but they will also receive a mark to their status and the buyer CAN review. Platform has 24 hours after cancellation to find substitute seller before order is automatically cancelled AND the customer can cancel at any time. Orders have a 5 minute no penalty cancellation grace window (for accidental purchase, changed mind, etc.) After 5 minutes, the order is finalized and buyer can only request cancellation. Within first 3 business days, buyer initiated cancellation is faulted to buyer. After 3 business days (if the item has not shipped), a buyer initiated cancellation is faulted to seller due to lack of promptness with shipping. In any case, seller has 24 hours to respond to cancellation request. Cancellation will automatically go through in 24 hours if seller does not respond.  
❌ Display a "x number sold recently" badge on items, similar to amazon/temu/etc.  
❌ Rank items by category and include a badge on high ranking items, similar to amazon (e.g. "#1 in concert tees")  
❌ Help sellers process damaged in shipment claims using insurance that comes with shipments.  
❌ Use Shippo API or similar to enable QR code package drop offs.  
❌ Use doordash and/or UPS services to enable door pickup / packaging services for a fee.  
❌ Enable local sales.        
❌ Display a price history on items to help buyers understand if they're getting a good deal or not. (May not help incentivize sales)  
  
🐞 Unresolved Bugs:  
❌ Screen flash when taking a photo does not cover tab bar navigator. (Probably need to move screen flashing to root directory or change zIndex to 0)
  
Sources / Attributions:  
Hacking with Swift Complete SwiftUI Beginner App Tutorial + Files (https://www.hackingwithswift.com/quick-start/swiftui/swiftui-tutorial-building-a-complete-project)  
Hacking with Swift @FocusState Tutorial (https://www.hackingwithswift.com/quick-start/swiftui/what-is-the-focusstate-property-wrapper)  
Hacking with Swift SwiftUI Scrollview Tutorial (https://www.hackingwithswift.com/quick-start/swiftui/how-to-add-horizontal-and-vertical-scrolling-using-scrollview)  
Hacking with Swift Adding Paging to ScrollView with ScrollTarget Tutorial (https://www.hackingwithswift.com/quick-start/swiftui/how-to-make-a-scrollview-snap-with-paging-or-between-child-views)  
Swiftful Thinking - Paging ScrollView in SwiftUI for iOS 17 and later (https://www.youtube.com/watch?v=hCpM95KHb_Q)  
Medium Blog Article - How to Implement Collection View in Swift UI Using LazyVGrid (https://bhoopendraumrao.medium.com/a-step-by-step-guide-to-implementing-collection-view-style-in-swiftui-db4c6989a4d)  
Swift UI Camera App Sample App for Camera Preview (https://developer.apple.com/tutorials/sample-apps/capturingphotos-camerapreview)  
Hacking with Swift - How to Change Ordering of Views in a ZStack (https://www.hackingwithswift.com/quick-start/swiftui/how-to-change-the-order-of-view-layering-using-z-index#:~:text=To%20do%20this%20you%20need,or%20below%20other%20views%20respectively.)  
Hacking with Swift - Customizing Animations in SwiftUI (https://www.hackingwithswift.com/books/ios-swiftui/customizing-animations-in-swiftui)  
