import SwiftUI
import Observation

private enum CarouselConfig {
    enum Layout {
        static let visibleCardCount = 8
        static let exitDistance: CGFloat = 400
        static let stackSpreadX: CGFloat = 45
        static let trajectorySlope: CGFloat = -0.45
    }
    enum Scale {
        static let exitReduction: CGFloat = 0.45
        static let stackReduction: CGFloat = 0.05
        static let minimum: CGFloat = 0.5
    }
    enum Physics {
        static let springTension: CGFloat = 60.0
        static let springFriction: CGFloat = 20.0
        static let stopThreshold: CGFloat = 0.001
    }
    enum Gesture {
        static let stretchElasticity: CGFloat = 0.08
        static let momentumSettleSpeed: CGFloat = 12.0
        static let swipeProjectionMultiplier: CGFloat = 0.5
    }
}

private final class DisplayLinkProxy: NSObject {
    var onFrame: ((CFTimeInterval) -> Void)?
    @objc func tick(link: CADisplayLink) {
        onFrame?(link.targetTimestamp)
    }
}

@MainActor
@Observable
final class CarouselState {
    var totalItemCount: UInt
    private var scrollPosition: CGFloat = 0
    private var swipeMomentum: CGFloat = 0
    
    @ObservationIgnored private var isDragging: Bool = false
    @ObservationIgnored private var targetScrollPosition: CGFloat = 0
    @ObservationIgnored private var velocity: CGFloat = 0
    @ObservationIgnored private var scrollPositionAtDragStart: CGFloat = 0
    
    @ObservationIgnored private nonisolated(unsafe) var displayLink: CADisplayLink?
    @ObservationIgnored private var displayLinkProxy: DisplayLinkProxy = DisplayLinkProxy()
    @ObservationIgnored private var lastFrameTime: CFTimeInterval = 0
    
    init(totalItemCount: UInt, startIndex: Int = 0) {
        self.totalItemCount = totalItemCount
        
        let clampedStart = max(0, min(startIndex, Int(totalItemCount) - 1))
        
        self.scrollPosition = CGFloat(clampedStart)
        self.targetScrollPosition = CGFloat(clampedStart)
        
        displayLinkProxy.onFrame = { [weak self] timestamp in
            self?.onFrame(timestamp: timestamp)
        }
    }
    
    deinit {
        displayLink?.invalidate()
    }
    
    var visibleIndices: Range<Int> {
        let lastIndex = Int(totalItemCount) - 1
        let currentIndex = Int(scrollPosition.rounded(.down))
        
        // FIX: Subtract 1 from currentIndex so the previous card
        // stays in the view hierarchy while it animates off-screen.
        let active = max(0, min(currentIndex - 1, lastIndex))
        
        let end = min(active + CarouselConfig.Layout.visibleCardCount, Int(totalItemCount))
        return active..<end
    }
    
    private func startSwipeEngine() {
        if displayLink != nil { return }
        lastFrameTime = 0
        
        let link = CADisplayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.tick(link:)))
        link.preferredFrameRateRange = .init(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        
        displayLink = link
    }
    
    func stopSwipeEngine() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    func onFrame(timestamp: CFTimeInterval) {
        if isDragging { return }
        
        let diff: CGFloat = lastFrameTime == 0 ? 1.0 / 120.0 : (timestamp - lastFrameTime)
        let deltaTime: CGFloat = min(diff, 1.0 / 30.0)
        
        lastFrameTime = timestamp
        
        let displacement = scrollPosition - targetScrollPosition
        
        let springForce = -CarouselConfig.Physics.springTension * displacement
        let dampingForce = -CarouselConfig.Physics.springFriction * velocity
        let acceleration = springForce + dampingForce
        
        velocity += acceleration * deltaTime
        scrollPosition += velocity * deltaTime
        
        swipeMomentum += (velocity - swipeMomentum) * (deltaTime * CarouselConfig.Gesture.momentumSettleSpeed)
        
        
        if abs(displacement) < CarouselConfig.Physics.stopThreshold && abs(velocity) < CarouselConfig.Physics.stopThreshold && abs(swipeMomentum) < CarouselConfig.Physics.stopThreshold {
            scrollPosition = targetScrollPosition
            velocity = 0
            swipeMomentum = 0
            stopSwipeEngine()
        }
    }
    
    private func stackDepthOffset(forCardAt index: Int) -> CGFloat {
        let distanceFromActiveCard = CGFloat(index) - scrollPosition
        
        guard distanceFromActiveCard > 0 else { return distanceFromActiveCard }
        
        let elasticStretch = distanceFromActiveCard * abs(swipeMomentum) * CarouselConfig.Gesture.stretchElasticity
        return distanceFromActiveCard + elasticStretch
    }
    
    func layout(for index: Int) -> (offset: CGSize, scale: CGFloat, zIndex: Double) {
        let relativeDepth = stackDepthOffset(forCardAt: index)
        
        let x = relativeDepth < 0
        ? relativeDepth * CarouselConfig.Layout.exitDistance
        : relativeDepth * CarouselConfig.Layout.stackSpreadX
        
        let offset = CGSize(
            width: x,
            height: x * CarouselConfig.Layout.trajectorySlope
        )
        
        let scale: CGFloat
        if relativeDepth < 0 {
            scale = 1.0 - (relativeDepth * CarouselConfig.Scale.exitReduction)
        } else {
            let reduction = relativeDepth * CarouselConfig.Scale.stackReduction
            scale = max(CarouselConfig.Scale.minimum, 1.0 - reduction)
        }
        
        let zIndex = -Double(relativeDepth)
        
        return (offset: offset, scale: scale, zIndex: zIndex)
    }
    
    func dragOnChanged(value: DragGesture.Value) {
        if !isDragging {
            isDragging = true
            scrollPositionAtDragStart = scrollPosition
            
            lastFrameTime = 0
            velocity = 0
            swipeMomentum = 0
        }
        
        let dragDelta = -(value.translation.width / CarouselConfig.Layout.exitDistance)
        scrollPosition = scrollPositionAtDragStart + dragDelta
    }
    
    func dragOnEnded(value: DragGesture.Value) {
        isDragging = false
        lastFrameTime = 0
        
        let releaseVelocity = -(value.velocity.width / CarouselConfig.Layout.exitDistance)
        self.velocity = releaseVelocity
        
        let projectedLandingPosition = (scrollPosition + (releaseVelocity * CarouselConfig.Gesture.swipeProjectionMultiplier)).rounded()
        targetScrollPosition = max(0, min(projectedLandingPosition, CGFloat(totalItemCount - 1)))
        
        startSwipeEngine()
    }
}

struct ContentView<Content: View>: View {
    @State private var state: CarouselState
    
    private var content: (Int) -> Content
    
    init(totalItemCount: UInt, startIndex: Int, @ViewBuilder content: @escaping (Int) -> Content) {
        self._state = State(initialValue: CarouselState(totalItemCount: totalItemCount, startIndex: startIndex))
        self.content = content
    }
    
    var body: some View {
        ZStack {
            ForEach(state.visibleIndices, id: \.self) { index in
                CarouselItemWrapper(state: state, index: index, content: content)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged(state.dragOnChanged)
                .onEnded(state.dragOnEnded)
        )
        .onDisappear {
            state.stopSwipeEngine()
        }
    }
}

struct CarouselItemWrapper<Content: View>: View {
    var state: CarouselState
    var index: Int
    @ViewBuilder var content: (Int) -> Content
    
    var body: some View {
        let layout = state.layout(for: index)
        
        content(index)
            .offset(layout.offset)
            .scaleEffect(layout.scale)
            .zIndex(layout.zIndex)
    }
}

struct CardView: View {
    var index: Int
    
    var body: some View {
        Text("\(index + 1)")
            .frame(width: 250, height: 350)
            .font(.system(size: 75, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .font(Font.system(size: 40, weight: .bold, design: .default))
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white)
                    .stroke(Color.black, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

#Preview {
    ContentView(totalItemCount: 100, startIndex: 10) { index in
        CardView(index: index)
    }
}
