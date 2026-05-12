/*
See the License.txt file for this sample’s licensing information.
*/

import SwiftUI

struct CameraView: View {
    @StateObject private var model = DataModel()
    @EnvironmentObject private var uploadManager: UploadManager
    @State private var isFlashing = false
    @State private var capturedImage: UIImage?
    @State private var showingModal = false
    @State private var selectedStackIndex = 0
    @State private var showingPicker = false
    
    private static let barHeightFactor = 0.15
    
    
    var body: some View {
        
        NavigationStack {
            ZStack{
                GeometryReader { geometry in
                    ViewfinderView(image:  $model.viewfinderImage )
                        .overlay(alignment: .top) {
                            // TODO: add back & publish button to top of view
                            Color.black
                                .opacity(0.75)
                                .frame(height: geometry.size.height * Self.barHeightFactor)
                        }
                        .overlay(alignment: .bottom) {
                            cameraButtonsView()
                                .frame(height: geometry.size.height * Self.barHeightFactor)
                                .background(.black.opacity(0.75))
                        }
                        .overlay(alignment: .bottom) {
                            if let firstStack = model.sessionPhotos.first, !firstStack.isEmpty{
                                photoStacksScrollView()
                                    .offset(y: -(geometry.size.height * Self.barHeightFactor) - 10) // Moves it up by the height of cameraButtonsView plus a small gap
                                }
                            }
                    
                        .overlay(alignment: .center)  {
                            Color.clear
                                .frame(height: geometry.size.height * (1 - (Self.barHeightFactor * 2)))
                                .accessibilityElement()
                                .accessibilityLabel("View Finder")
                                .accessibilityAddTraits([.isImage])
                        }
                        .background(.black)
                }
                //TODO: White flash does not cover tab bar items
                // Possible fix: Move view to mainView of app. Move isFlashing to @Environment level variable.
                // White flash overlay
                if isFlashing {
                    Color.white
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: isFlashing)
                        .onAppear() {
                            // After 0.2 seconds, make view disappear
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isFlashing = false
                                }
                            }
                        }
                }
            }

            .task {
                await model.camera.start()
                await model.loadPhotos()
                await model.loadThumbnail()
            }
            //.navigationTitle("Camera")
            //.navigationBarTitleDisplayMode(.inline)
            //.navigationBarHidden(true)
            //.ignoresSafeArea()
            //.statusBar(hidden: true)
            .sheet(isPresented: $showingModal) {
                PhotoStackModalView(
                    dataModel: model,
                    isPresented: $showingModal,
                    stackIndex: selectedStackIndex
                )
            }
        }
    }
    
    private func cameraButtonsView() -> some View {
        HStack(spacing: 60) {
            
            Spacer()
            
            NavigationLink(isActive: $showingPicker) {
                CustomPhotoPickerView()
                    .onAppear { model.camera.isPreviewPaused = true }
                    .onDisappear { model.camera.isPreviewPaused = false }
            } label: {
                Label {
                    Text("Gallery")
                } icon: {
                    ThumbnailView(image: model.thumbnailImage)
                }
            }
            .onChange(of: uploadManager.shouldReturnToRoot) { _, should in
                if should {
                    showingPicker = false
                    uploadManager.shouldReturnToRoot = false
                }
            }
            
            Button {
                model.camera.takePhoto()
                //MARK: Is this best way to trigger flashing animation?
                isFlashing = true
            } label: {
                Label {
                    Text("Take Photo")
                } icon: {
                    ZStack {
                        Circle()
                            .strokeBorder(.white, lineWidth: 3)
                            .frame(width: 62, height: 62)
                        Circle()
                            .fill(.white)
                            .frame(width: 50, height: 50)
                    }
                }
            }
            
            Button {
                model.camera.switchCaptureDevice()
            } label: {
                Label("Switch Camera", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)
            }
            
            Spacer()
        
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .padding()
    }

    private func photoStacksScrollView() -> some View {
        HStack {
            PhotoStackView(
                sessionPhotos: model.sessionPhotos,
                onStackTapped: { stackIndex in
                    selectedStackIndex = stackIndex
                    showingModal = true
                }
            )
                .frame(height: 100)
            
            Button(action: {
                model.addNewStack()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(10)
            }
        }
    }

    private struct PhotoStackView: View {
        let sessionPhotos: [[UIImage]]
        let onStackTapped: (Int) -> Void
        
        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack{
                    ForEach(0..<sessionPhotos.count, id: \.self) { stackIndex in
                        SinglePhotoStackView(photos: sessionPhotos[stackIndex])
                            .padding(.top, 20)   // Adds 20 points of padding to the top
                            .padding(.leading, stackIndex == 0 ? 15 : 0) // Only first stack gets leading padding
                            .padding(.trailing, 20)
                            .onTapGesture {
                                onStackTapped(stackIndex)
                            }
                    }
                }
            }
        }
    }

    private struct SinglePhotoStackView: View {
        let photos: [UIImage]
        
        var body: some View {
            ZStack(alignment: .topLeading) {
                ForEach(0..<photos.count, id: \.self) { photoIndex in
                    Image(uiImage: photos[photoIndex])
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80)
                        .cornerRadius(10)
                        .offset(
                            x: photoIndex < 3 ? CGFloat(photoIndex) * 10 : 0, // Stagger horizontally for first 3 photos
                            y: photoIndex < 3 ? CGFloat(photoIndex) * -10 : 0 // Stagger vertically for first 3 photos
                        )
                        .zIndex(photoIndex < 3 ? CGFloat(3 - photoIndex) : 0) // Subsequent photos appear behind top photo
                }
            }
            .frame(height: 100) // Ensure the stack has enough space
        }
    }
}
