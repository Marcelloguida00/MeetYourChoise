import RealityKit
import SwiftUI
import Combine
import CoreHaptics

struct DiceView: View {
    @State private var lastResult: Int?
    @State private var faceCount: Int = 6
    @State private var showCustomize: Bool = false

    var body: some View {
        ZStack {
            DiceViewContainer(faceCount: faceCount, onResult: { number in
                lastResult = number
                // Show the winner text for 5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        lastResult = nil
                    }
                }
            })
            .edgesIgnoringSafeArea(.all)

            if let number = lastResult {
                VStack {
                    Spacer()
                    Text("d\(faceCount): \(number)")
                        .font(.system(size: 36, weight: .bold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button("Customize") {
                        showCustomize = true
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding([.top, .trailing], 16)
                }
                Spacer()
            }
            .sheet(isPresented: $showCustomize) {
                CustomizeSheet(faceCount: $faceCount)
            }
        }
    }
}

struct DiceViewContainer: UIViewRepresentable {
    var faceCount: Int = 6
    var onResult: ((Int) -> Void)? = nil
    private let playPlaneZ: Float = -0.5
    private var sideThickness: Float { 0.02 }
    
    func makeUIView(context: Context) -> ARView {
        let arView = ShakeARView(frame: .zero)
        
        // Set background color (no AR camera)
        arView.environment.background = .color(.clear)
        
        arView.onShake = { [weak coordinator = context.coordinator] in
            coordinator?.rollDice()
        }
        
        // Create anchor
        let anchor = AnchorEntity()
        
        context.coordinator.anchor = anchor
        context.coordinator.playPlaneZ = playPlaneZ
        context.coordinator.sideThickness = sideThickness
        context.coordinator.makeFloor = { width, depth, z in
            createFloor(width: width, depth: depth, z: z)
        }
        context.coordinator.makeDie = { faces in
            createDice(for: faces)
        }
        
        // Defer boundary creation to coordinator (depends on view size & camera)
        context.coordinator.installOrUpdateBoundaries(in: arView, on: anchor)
        // Ensure another pass after initial layout cycle
        DispatchQueue.main.async { [weak coordinator = context.coordinator, weak arView] in
            guard let arView = arView else { return }
            coordinator?.installOrUpdateBoundaries(in: arView, on: anchor)
        }
        
        // Create and position dice
        let dice = createDice(for: faceCount)
        dice.position = [0, 0, -0.5]
        anchor.addChild(dice)
        // Temporarily make the dice kinematic until boundaries are installed
        if var body = dice.components[PhysicsBodyComponent.self] {
            body.mode = .kinematic
            dice.components.set(body)
        }
        
        // Add lighting
        addLighting(to: anchor)
        
        // Camera dall'alto (top-down) - più in alto per vedere l'area più grande
        let camera = PerspectiveCamera()
        let cameraHolder = Entity()
        cameraHolder.position = [0, 1.5, -0.5] // Aumentato da 0.8 a 1.5
        cameraHolder.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]) // guarda verso -Y
        cameraHolder.addChild(camera)
        anchor.addChild(cameraHolder)
        
        arView.scene.addAnchor(anchor)
        
        // Add fireworks overlay view (2D) on top of ARView
        let fireworks = FireworksOverlay(frame: arView.bounds)
        fireworks.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(fireworks)
        
        // Store references
        context.coordinator.arView = arView
        context.coordinator.dice = dice
        context.coordinator.onResult = onResult
        context.coordinator.fireworksView = fireworks
        context.coordinator.faceCount = faceCount
        
        context.coordinator.startObservingSceneUpdates()
        
        // Add gestures
        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        arView.addGestureRecognizer(tapGesture)
        
        let panGesture = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        arView.addGestureRecognizer(panGesture)
        
        // Observe layout changes to keep boundaries matching screen
        arView.addSubview(ResizeObserver { [weak coordinator = context.coordinator, weak arView] in
            guard let arView = arView else { return }
            coordinator?.installOrUpdateBoundaries(in: arView, on: anchor)
        })
        
        _ = arView.becomeFirstResponder()
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        if context.coordinator.faceCount != faceCount {
            context.coordinator.faceCount = faceCount
            context.coordinator.onFaceCountChanged()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func createDice(for faces: Int) -> ModelEntity {
        if faces == 4 {
            return createTetrahedronDie()
        } else if faces != 6 {
            return createPrismDie(sides: max(3, faces))
        }
        let size: Float = 0.1
        let half: Float = size / 2
        let epsilon: Float = 0.001 // slightly larger offset to avoid z-fighting

        // Container for the dice faces
        let dice = ModelEntity()

        // Helper to build a material with the face texture
        func material(for number: Int) -> SimpleMaterial {
            var mat = SimpleMaterial()
            if let cgImage = createDiceFaceTexture(number: number),
               let textureResource = try? TextureResource(image: cgImage, options: .init(semantic: .color)) {
                mat.color = .init(tint: .white, texture: .init(textureResource))
                mat.faceCulling = .none
            } else {
                // Fallback: solid black face if texture generation fails
                mat.color = .init(tint: .black)
                mat.faceCulling = .none
            }
            return mat
        }

        // A single plane mesh we will reuse for all faces. Default normal is +Y.
        let planeMesh = MeshResource.generatePlane(width: size, depth: size)

        // Build each face with correct orientation and position.
        // Mapping numbers so opposite faces sum to 7: (+X=3, -X=4, +Y=6, -Y=1, +Z=2, -Z=5)

        // Top (+Y)
        do {
            let face = ModelEntity(mesh: planeMesh, materials: [material(for: 6)])
            face.position = [0, half + epsilon, 0]
            face.orientation = simd_quatf(angle: 0, axis: [1, 0, 0])
            dice.addChild(face)
        }

        // Bottom (-Y)
        do {
            let face = ModelEntity(mesh: planeMesh, materials: [material(for: 1)])
            face.position = [0, -half - epsilon, 0]
            face.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])
            dice.addChild(face)
        }

        // Front (+Z)
        do {
            let face = ModelEntity(mesh: planeMesh, materials: [material(for: 2)])
            face.position = [0, 0, half + epsilon]
            face.orientation = simd_quatf(angle: -.pi/2, axis: [1, 0, 0])
            dice.addChild(face)
        }

        // Back (-Z)
        do {
            let face = ModelEntity(mesh: planeMesh, materials: [material(for: 5)])
            face.position = [0, 0, -half - epsilon]
            face.orientation = simd_quatf(angle: .pi/2, axis: [1, 0, 0])
            dice.addChild(face)
        }

        // Right (+X)
        do {
            let face = ModelEntity(mesh: planeMesh, materials: [material(for: 3)])
            face.position = [half + epsilon, 0, 0]
            face.orientation = simd_quatf(angle: -.pi/2, axis: [0, 0, 1])
            dice.addChild(face)
        }

        // Left (-X)
        do {
            let face = ModelEntity(mesh: planeMesh, materials: [material(for: 4)])
            face.position = [-half - epsilon, 0, 0]
            face.orientation = simd_quatf(angle: .pi/2, axis: [0, 0, 1])
            dice.addChild(face)
        }

        // Physics and collision on the container (use a solid box collider)
        let physicsMaterial = PhysicsMaterialResource.generate(
            staticFriction: 0.05,
            dynamicFriction: 0.03,
            restitution: 0.9
        )

        dice.components.set(PhysicsBodyComponent(
            massProperties: .default,
            material: physicsMaterial,
            mode: .dynamic
        ))

        // Ensure motion component exists so we can read velocities during updates
        if dice.components[PhysicsMotionComponent.self] == nil {
            dice.components.set(PhysicsMotionComponent())
        }
        if var body = dice.components[PhysicsBodyComponent.self] {
            body.linearDamping = 0.02
            body.angularDamping = 0.02
            dice.components.set(body)
        }

        dice.collision = CollisionComponent(
            shapes: [.generateBox(size: [size, size, size])]
        )

        print("Dado creato con 6 facce piane orientate correttamente, numeri: 1,2,3,4,5,6")

        return dice
    }
    
    func createPrismDie(sides: Int) -> ModelEntity {
        let radius: Float = 0.06
        let height: Float = 0.1
        var descriptor = MeshDescriptor()

        // Generate vertices for top and bottom n-gon
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        let topY: Float = height / 2
        let bottomY: Float = -height / 2

        for i in 0..<sides {
            let angle = (Float(i) / Float(sides)) * (2 * .pi)
            let x = cos(angle) * radius
            let z = sin(angle) * radius
            // Top ring
            positions.append([x, topY, z])
            normals.append(simd_normalize([x, 0, z]))
            uvs.append([Float(i)/Float(sides), 0])
            // Bottom ring
            positions.append([x, bottomY, z])
            normals.append(simd_normalize([x, 0, z]))
            uvs.append([Float(i)/Float(sides), 1])
        }

        // Center vertices for caps
        let topCenterIndex = positions.count
        positions.append([0, topY, 0])
        normals.append([0, 1, 0])
        uvs.append([0.5, 0.5])

        let bottomCenterIndex = positions.count
        positions.append([0, bottomY, 0])
        normals.append([0, -1, 0])
        uvs.append([0.5, 0.5])

        // Indices
        var indices: [UInt32] = []

        // Side faces (two triangles per side)
        for i in 0..<sides {
            let next = (i + 1) % sides
            let topA = UInt32(i * 2)
            let botA = UInt32(i * 2 + 1)
            let topB = UInt32(next * 2)
            let botB = UInt32(next * 2 + 1)
            // Triangle 1
            indices.append(contentsOf: [topA, botA, topB])
            // Triangle 2
            indices.append(contentsOf: [botA, botB, topB])
        }

        // Top cap (fan)
        for i in 0..<sides {
            let next = (i + 1) % sides
            let topA = UInt32(i * 2)
            let topB = UInt32(next * 2)
            indices.append(contentsOf: [UInt32(topCenterIndex), topB, topA])
        }

        // Bottom cap (fan)
        for i in 0..<sides {
            let next = (i + 1) % sides
            let botA = UInt32(i * 2 + 1)
            let botB = UInt32(next * 2 + 1)
            indices.append(contentsOf: [UInt32(bottomCenterIndex), botA, botB])
        }

        descriptor.positions = .init(positions)
        descriptor.normals = .init(normals)
        descriptor.primitives = .triangles(indices)

        let mesh: MeshResource
        do {
            mesh = try MeshResource.generate(from: [descriptor])
        } catch {
            // Fallback to a simple box if mesh generation fails
            return createDice(for: 6)
        }

        var material = SimpleMaterial()
        material.color = .init(tint: .black)
        let die = ModelEntity(mesh: mesh, materials: [material])

        // Physics setup (convex box approximation)
        let physicsMaterial = PhysicsMaterialResource.generate(
            staticFriction: 0.05,
            dynamicFriction: 0.03,
            restitution: 0.9
        )
        die.components.set(PhysicsBodyComponent(massProperties: .default, material: physicsMaterial, mode: .dynamic))
        if die.components[PhysicsMotionComponent.self] == nil {
            die.components.set(PhysicsMotionComponent())
        }
        if var body = die.components[PhysicsBodyComponent.self] {
            body.linearDamping = 0.02
            body.angularDamping = 0.02
            die.components.set(body)
        }
        // Collision: convex from mesh if available, else box
        do {
            let shape = try ShapeResource.generateConvex(from: mesh)
            die.collision = CollisionComponent(shapes: [shape])
        } catch {
            die.collision = CollisionComponent(shapes: [.generateBox(size: [radius * 2, height, radius * 2])])
        }

        return die
    }
    
    func createTetrahedronDie() -> ModelEntity {
        // Regular tetrahedron vertices centered at origin
        // Using vertices at permutations of (±1, ±1, ±1) with an odd number of negatives
        let v0 = SIMD3<Float>( 1,  1,  1)
        let v1 = SIMD3<Float>( 1, -1, -1)
        let v2 = SIMD3<Float>(-1,  1, -1)
        let v3 = SIMD3<Float>(-1, -1,  1)

        // Scale to a comfortable size (circumradius about ~0.085)
        let targetRadius: Float = 0.085
        let currentRadius: Float = length(v0) // all have same length sqrt(3)
        let s: Float = targetRadius / currentRadius

        let p0 = v0 * s
        let p1 = v1 * s
        let p2 = v2 * s
        let p3 = v3 * s

        // Triangular faces (ensure counter-clockwise winding when looking from outside)
        let faces: [[SIMD3<Float>]] = [
            [p0, p1, p2],
            [p0, p3, p1],
            [p0, p2, p3],
            [p1, p3, p2]
        ]

        var descriptor = MeshDescriptor()
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for (fi, tri) in faces.enumerated() {
            let a = tri[0]
            let b = tri[1]
            let c = tri[2]
            let n = normalize(cross(b - a, c - a))
            let base = UInt32(positions.count)
            positions.append(contentsOf: [a, b, c])
            normals.append(contentsOf: [n, n, n])
            indices.append(contentsOf: [base, base + 1, base + 2])
        }

        descriptor.positions = .init(positions)
        descriptor.normals = .init(normals)
        descriptor.primitives = .triangles(indices)

        let mesh: MeshResource
        do {
            mesh = try MeshResource.generate(from: [descriptor])
        } catch {
            return createDice(for: 6)
        }

        var material = SimpleMaterial()
        material.color = .init(tint: .black)
        let die = ModelEntity(mesh: mesh, materials: [material])

        // Add textured overlays with white pips for each face
        let overlayOffset: Float = 0.0015 // lift overlays slightly above the face to avoid z-fighting
        for (index, tri) in faces.enumerated() {
            let a = tri[0]
            let b = tri[1]
            let c = tri[2]
            let n = normalize(cross(b - a, c - a))

            var faceDesc = MeshDescriptor()
            // Slightly offset along the normal to avoid z-fighting with the base mesh
            faceDesc.positions = .init([a + n * overlayOffset, b + n * overlayOffset, c + n * overlayOffset])
            faceDesc.normals = .init([n, n, n])
            // Map the triangle to a full square texture using a conventional triangle UV
            faceDesc.textureCoordinates = .init([SIMD2<Float>(0.5, 1.0), SIMD2<Float>(0.0, 0.0), SIMD2<Float>(1.0, 0.0)])
            faceDesc.primitives = .triangles([0, 1, 2])

            guard let faceMesh = try? MeshResource.generate(from: [faceDesc]) else { continue }

            var faceMaterial = SimpleMaterial()
            if let cgImage = createTetraFaceTexture(number: index + 1),
               let textureResource = try? TextureResource(image: cgImage, options: .init(semantic: .color)) {
                faceMaterial.color = .init(tint: .white, texture: .init(textureResource))
                faceMaterial.faceCulling = .none
            } else {
                faceMaterial.color = .init(tint: .black)
                faceMaterial.faceCulling = .none
            }

            let faceEntity = ModelEntity(mesh: faceMesh, materials: [faceMaterial])
            die.addChild(faceEntity)
        }

        // Physics and collision
        let physicsMaterial = PhysicsMaterialResource.generate(
            staticFriction: 0.05,
            dynamicFriction: 0.03,
            restitution: 0.9
        )
        die.components.set(PhysicsBodyComponent(massProperties: .default, material: physicsMaterial, mode: .dynamic))
        if die.components[PhysicsMotionComponent.self] == nil {
            die.components.set(PhysicsMotionComponent())
        }
        if var body = die.components[PhysicsBodyComponent.self] {
            body.linearDamping = 0.02
            body.angularDamping = 0.02
            die.components.set(body)
        }

        do {
            let shape = try ShapeResource.generateConvex(from: mesh)
            die.collision = CollisionComponent(shapes: [shape])
        } catch {
            // Fallback: approximate with a box
            die.collision = CollisionComponent(shapes: [.generateBox(size: [targetRadius * 2, targetRadius * 2, targetRadius * 2])])
        }

        return die
    }
    
    func createTetraFaceTexture(number: Int) -> CGImage? {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            // Background: black
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Draw white pips (circles)
            let cg = context.cgContext
            cg.setShouldAntialias(true)
            cg.setFillColor(UIColor.white.cgColor)

            // Define triangle corners in texture space matching the UVs used above
            let top = CGPoint(x: size.width * 0.5, y: size.height * 0.08)
            let left = CGPoint(x: size.width * 0.10, y: size.height * 0.90)
            let right = CGPoint(x: size.width * 0.90, y: size.height * 0.90)

            // Helper to draw a dot
            func dot(_ p: CGPoint, r: CGFloat) {
                cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2*r, height: 2*r))
            }

            // Reasonable radius for 512x512
            let r: CGFloat = size.width * 0.06

            switch number {
            case 1:
                // Center of triangle
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.55)
                dot(center, r: r)
            case 2:
                // Near left and right corners
                let p1 = CGPoint(x: left.x + 30, y: left.y - 30)
                let p2 = CGPoint(x: right.x - 30, y: right.y - 30)
                dot(p1, r: r)
                dot(p2, r: r)
            case 3:
                // Three corners
                dot(left, r: r)
                dot(right, r: r)
                dot(top, r: r)
            case 4:
                // Three corners + center
                dot(left, r: r)
                dot(right, r: r)
                dot(top, r: r)
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.55)
                dot(center, r: r)
            default:
                // Fallback: just a single center dot
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.55)
                dot(center, r: r)
            }
        }
        return image.cgImage
    }

    func createFloor(width: Float, depth: Float, z: Float) -> ModelEntity {
        let mesh = MeshResource.generatePlane(width: width, depth: depth)
        var material = SimpleMaterial()
        material.color = .init(tint: .clear)
        let floor = ModelEntity(mesh: mesh, materials: [material])
        floor.position = [0, 0, z]
        floor.components.set(PhysicsBodyComponent(
            massProperties: .default,
            material: .generate(restitution: 0.95),
            mode: .static
        ))
        floor.collision = CollisionComponent(
            shapes: [.generateBox(width: width, height: 0.01, depth: depth)]
        )
        return floor
    }
    
    func addLighting(to anchor: AnchorEntity) {
        let directionalLight = DirectionalLight()
        directionalLight.light.intensity = 2000
        directionalLight.shadow = DirectionalLightComponent.Shadow()
        
        let lightAnchor = AnchorEntity()
        lightAnchor.position = [0, 1, 0]
        lightAnchor.look(at: [0, 0, 0], from: lightAnchor.position, relativeTo: nil)
        lightAnchor.addChild(directionalLight)
        
        anchor.addChild(lightAnchor)
    }
    
    func createDiceFaceTexture(number: Int) -> CGImage? {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)

        let image = renderer.image { context in
            // Background: black
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Draw white pips
            let cg = context.cgContext
            cg.setShouldAntialias(true)
            cg.setFillColor(UIColor.white.cgColor)

            // Reasonable radius for 512x512
            let dotRadius: CGFloat = size.width * 0.085
            drawDots(for: number, in: cg, size: size, dotRadius: dotRadius)
        }

        return image.cgImage
    }
    
    func drawDots(for number: Int, in context: CGContext, size: CGSize, dotRadius: CGFloat) {
        let centerX = size.width / 2
        let centerY = size.height / 2
        let offset: CGFloat = 120
        
        switch number {
        case 1:
            drawDot(at: CGPoint(x: centerX, y: centerY), radius: dotRadius, in: context)
        case 2:
            drawDot(at: CGPoint(x: centerX - offset, y: centerY - offset), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX + offset, y: centerY + offset), radius: dotRadius, in: context)
        case 3:
            drawDot(at: CGPoint(x: centerX - offset, y: centerY - offset), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX, y: centerY), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX + offset, y: centerY + offset), radius: dotRadius, in: context)
        case 4:
            drawDot(at: CGPoint(x: centerX - offset, y: centerY - offset), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX + offset, y: centerY - offset), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX - offset, y: centerY + offset), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX + offset, y: centerY + offset), radius: dotRadius, in: context)
        case 5:
            drawDot(at: CGPoint(x: centerX - offset, y: centerY - offset), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX + offset, y: centerY - offset), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX, y: centerY), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX - offset, y: centerY + offset), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX + offset, y: centerY + offset), radius: dotRadius, in: context)
        case 6:
            drawDot(at: CGPoint(x: centerX - offset, y: centerY - offset), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX + offset, y: centerY - offset), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX - offset, y: centerY), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX + offset, y: centerY), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX - offset, y: centerY + offset), radius: dotRadius, in: context)
            drawDot(at: CGPoint(x: centerX + offset, y: centerY + offset), radius: dotRadius, in: context)
        default:
            break
        }
    }
    
    func drawDot(at point: CGPoint, radius: CGFloat, in context: CGContext) {
        context.fillEllipse(in: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }
    
    class ResizeObserver: UIView {
        private let onLayout: () -> Void
        init(_ onLayout: @escaping () -> Void) {
            self.onLayout = onLayout
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout()
        }
    }
    
    class ShakeARView: ARView {
        var onShake: (() -> Void)?
        override var canBecomeFirstResponder: Bool { true }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { _ = becomeFirstResponder() }
        }
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake { onShake?() }
            super.motionEnded(motion, with: event)
        }
    }
    
    class Coordinator {
        var onResult: ((Int) -> Void)?
        var arView: ARView?
        var dice: ModelEntity?
        var anchor: AnchorEntity?
        var playPlaneZ: Float = -0.5
        var sideThickness: Float = 0.02
        private var installed: Bool = false
        private var wallEntities: [Entity] = []
        private var floorEntity: Entity?
        var makeFloor: ((Float, Float, Float) -> ModelEntity)?
        var makeDie: ((Int) -> ModelEntity)?
        
        var fireworksView: FireworksOverlay?
        var faceCount: Int = 6
        
        private var sceneUpdateCancellable: (any Cancellable)?
        private var settleTimer: TimeInterval = 0
        private var lastUpdateTime: TimeInterval?
        private var isRecentering: Bool = false
        private var recenterCooldown: TimeInterval = 0
        private var recenterTimer: Timer?
        
        private var lastPosition: SIMD3<Float>?
        private var lastRotation: simd_quatf?
        
        private var hapticEngine: CHHapticEngine?
        private var hapticPlayer: CHHapticAdvancedPatternPlayer?
        private var wasMoving: Bool = false
        
        private var hasAnnouncedResult: Bool = false
        private var awaitingResult: Bool = false
        
        private func setupHaptics() {
            guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
            do {
                hapticEngine = try CHHapticEngine()
                try hapticEngine?.start()
            } catch {
                print("Haptics: failed to start engine: \(error)")
                hapticEngine = nil
            }
        }

        private func startRollingHaptics() {
            guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
                // Fallback: single impact to indicate start
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                return
            }
            // If engine not set up, set it up now
            if hapticEngine == nil { setupHaptics() }
            do {
                // Continuous haptic while the dice is moving
                let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5)
                let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
                let continuous = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness], relativeTime: 0, duration: 10)
                let pattern = try CHHapticPattern(events: [continuous], parameters: [])
                hapticPlayer = try hapticEngine?.makeAdvancedPlayer(with: pattern)
                try hapticPlayer?.start(atTime: 0)
            } catch {
                print("Haptics: failed to start player: \(error)")
            }
        }

        private func stopRollingHaptics() {
            if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
                do {
                    try hapticPlayer?.stop(atTime: 0)
                    hapticPlayer = nil
                    // Gentle end tap
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                } catch {
                    print("Haptics: failed to stop player: \(error)")
                }
            } else {
                // Fallback: light impact to indicate stop
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        
        func startObservingSceneUpdates() {
            guard let arView = arView else { return }
            setupHaptics()
            sceneUpdateCancellable?.cancel()
            sceneUpdateCancellable = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                self?.handleSceneUpdate(event)
            }
        }
        
        private func handleSceneUpdate(_ event: SceneEvents.Update) {
            guard let dice = dice else { return }
            
            // Cooldown to avoid repeated recenters
            if recenterCooldown > 0 {
                recenterCooldown -= event.deltaTime
            }
            
            // Read physics motion state (fallback to pose deltas if motion not available)
            var linearSpeed: Float = 0
            var angularSpeed: Float = 0
            if let motion = dice.components[PhysicsMotionComponent.self] {
                linearSpeed = simd_length(motion.linearVelocity)
                angularSpeed = simd_length(motion.angularVelocity)
            } else {
                // Approximate speeds using position/rotation deltas
                if let lastPos = lastPosition, let lastRot = lastRotation, event.deltaTime > 0 {
                    let posDelta = simd_length(dice.position - lastPos)
                    linearSpeed = posDelta / Float(event.deltaTime)
                    let deltaQ = dice.transform.rotation * simd_inverse(lastRot)
                    let clamped = max(-1.0, min(1.0, Double(deltaQ.real)))
                    let angle = Float(2.0 * acos(clamped))
                    angularSpeed = angle / Float(event.deltaTime)
                }
            }
            // Compute vertical speed (prefer motion if available)
            var verticalSpeedAbs: Float = 0
            if let motion = dice.components[PhysicsMotionComponent.self] {
                verticalSpeedAbs = abs(motion.linearVelocity.y)
            } else if let lastPos = lastPosition, event.deltaTime > 0 {
                verticalSpeedAbs = abs((dice.position.y - lastPos.y) / Float(event.deltaTime))
            }
            // Consider near-floor when y is close to expected resting height (0.05)
            let nearFloor = abs(dice.position.y - 0.05) < 0.02
            
            // Determine moving state
            let movingThresholdLinear: Float = 0.02
            let movingThresholdAngular: Float = 0.1
            let isMoving = (linearSpeed > movingThresholdLinear) || (angularSpeed > movingThresholdAngular)
            
            // Start/stop haptics on transition
            if isMoving && !wasMoving {
                startRollingHaptics()
            }
            if !isMoving && wasMoving {
                stopRollingHaptics()
            }
            
            if isMoving {
                // Any movement cancels previous announcement so a new result can be announced later
                hasAnnouncedResult = false
            }
            
            // Thresholds for considering the dice as settled (stricter)
            let linearThreshold: Float = 0.015
            let angularThreshold: Float = 0.08
            let verticalThreshold: Float = 0.02
            
            if linearSpeed < linearThreshold && angularSpeed < angularThreshold && verticalSpeedAbs < verticalThreshold && nearFloor && awaitingResult && !hasAnnouncedResult {
                settleTimer += event.deltaTime
                
                // Start recentering after 0.6 seconds of being settled
                if settleTimer > 0.6 && !isRecentering && recenterCooldown <= 0 && !hasAnnouncedResult {
                    startRecenterAndShowResult()
                }
            } else {
                // Reset timer if dice starts moving again
                settleTimer = 0
                cancelRecenterTimer()
            }
            
            // Track last pose for next frame
            lastPosition = dice.position
            lastRotation = dice.transform.rotation
            
            wasMoving = (linearSpeed > 0.02) || (angularSpeed > 0.1)
        }
        
        private func determineTopFace() -> (number: Int, faceOrientation: simd_quatf)? {
            guard let dice = dice else { return nil }
            let q = dice.transform.rotation
            let worldUp = SIMD3<Float>(0, 1, 0)

            // Define local face normals and their creation orientations
            let faces: [(normal: SIMD3<Float>, number: Int, orientation: simd_quatf)] = [
                (SIMD3<Float>(0,  1,  0), 6, simd_quatf(angle: 0, axis: [1, 0, 0])),
                (SIMD3<Float>(0, -1,  0), 1, simd_quatf(angle: .pi, axis: [1, 0, 0])),
                (SIMD3<Float>(0,  0,  1), 2, simd_quatf(angle: -.pi/2, axis: [1, 0, 0])),
                (SIMD3<Float>(0,  0, -1), 5, simd_quatf(angle:  .pi/2, axis: [1, 0, 0])),
                (SIMD3<Float>(1,  0,  0), 3, simd_quatf(angle: -.pi/2, axis: [0, 0, 1])),
                (SIMD3<Float>(-1, 0,  0), 4, simd_quatf(angle:  .pi/2, axis: [0, 0, 1]))
            ]

            var best: (number: Int, orientation: simd_quatf, score: Float)?
            for f in faces {
                let worldNormal = simd_act(q, f.normal)
                let score = simd_dot(worldNormal, worldUp)
                if best == nil || score > best!.score {
                    best = (f.number, f.orientation, score)
                }
            }
            guard let b = best else { return nil }
            return (b.number, b.orientation)
        }

        // Added helper method
        private func targetRotationForTop(number: Int) -> simd_quatf {
            switch number {
            case 6:
                // +Y on top
                return simd_quatf(angle: 0, axis: [0, 1, 0])
            case 1:
                // -Y to +Y
                return simd_quatf(angle: .pi, axis: [1, 0, 0])
            case 2:
                // +Z to +Y
                return simd_quatf(angle: -.pi/2, axis: [1, 0, 0])
            case 5:
                // -Z to +Y
                return simd_quatf(angle:  .pi/2, axis: [1, 0, 0])
            case 3:
                // +X to +Y
                return simd_quatf(angle:  .pi/2, axis: [0, 0, 1])
            case 4:
                // -X to +Y
                return simd_quatf(angle: -.pi/2, axis: [0, 0, 1])
            default:
                return simd_quatf(angle: 0, axis: [0, 1, 0])
            }
        }
        
        private func startRecenterAndShowResult() {
            guard let dice = dice, !isRecentering else { return }
            guard awaitingResult else { return }

            let currentPos = dice.position
            // Lift slightly above the floor to avoid interpenetration while rotating
            let liftedY: Float = max(currentPos.y, 0.07)
            let targetPos = SIMD3<Float>(0, liftedY, playPlaneZ)

            // Determine result
            let winningNumber: Int
            let targetRotation: simd_quatf
            if faceCount == 6, let result = determineTopFace() {
                winningNumber = result.number
                targetRotation = targetRotationForTop(number: result.number)
            } else {
                // For non-6-faced configurations, pick a fair random result
                winningNumber = max(1, Int.random(in: 1...max(1, faceCount)))
                // Keep current orientation when recentring
                targetRotation = dice.transform.rotation
            }

            print("Starting recenter to center with result: \(winningNumber)")

            isRecentering = true
            recenterCooldown = 5.0

            // Make the body kinematic during the animation to avoid physics fighting the motion
            if var body = dice.components[PhysicsBodyComponent.self] {
                body.mode = .kinematic
                dice.components.set(body)
            }

            animateDiceToCenter(to: targetPos, targetRotation: targetRotation) { [weak self] in
                guard let self = self, let dice = self.dice else { return }

                // Brief highlight: small scale pulse to emphasize the number
                let originalScale = dice.scale
                let highlightScale = SIMD3<Float>(repeating: 1.08)
                var t: Float = 0
                let duration: Float = 0.18
                let frameRate: Float = 60
                let step = 1.0 / (duration * frameRate)

                Timer.scheduledTimer(withTimeInterval: 1.0/Double(frameRate), repeats: true) { timer in
                    t += step
                    if t >= 1.0 {
                        dice.scale = originalScale
                        timer.invalidate()

                        // Snap to resting height (dice size is 0.1 -> half = 0.05)
                        dice.position.y = 0.05

                        // Restore physics to dynamic and zero velocities
                        if var body = dice.components[PhysicsBodyComponent.self] {
                            body.mode = .dynamic
                            dice.components.set(body)
                        }

                        // Reset motion
                        if var motion = dice.components[PhysicsMotionComponent.self] {
                            motion.linearVelocity = .zero
                            motion.angularVelocity = .zero
                            dice.components.set(motion)
                        }

                        // Notify SwiftUI about the result
                        self.onResult?(winningNumber)
                        if let arView = self.arView {
                            let worldPos = dice.position(relativeTo: nil)
                            if let screenPoint = arView.project(worldPos) {
                                self.fireworksView?.explode(at: screenPoint, duration: 5.0)
                            } else {
                                // Fallback: center of the screen
                                let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
                                self.fireworksView?.explode(at: center, duration: 5.0)
                            }
                        }
                        self.awaitingResult = false
                        self.hasAnnouncedResult = true

                        self.isRecentering = false
                        self.stopRollingHaptics()
                    } else {
                        // ease in-out
                        let p = t * t * (3 - 2 * t)
                        if t < 0.5 {
                            let q = p * 2
                            dice.scale = originalScale + (highlightScale - originalScale) * q
                        } else {
                            let q = (1 - p) * 2
                            dice.scale = originalScale + (highlightScale - originalScale) * max(0, q)
                        }
                    }
                }
            }
        }
        
        private func animateDiceToCenter(to targetPos: SIMD3<Float>, targetRotation: simd_quatf, completion: (() -> Void)? = nil) {
            guard let dice = dice else { return }

            let startPos = dice.position
            let startRotation = dice.transform.rotation

            var progress: Float = 0.0
            let duration: Float = 0.6
            let frameRate: Float = 60.0
            let increment = 1.0 / (duration * frameRate)

            recenterTimer?.invalidate()
            recenterTimer = Timer.scheduledTimer(withTimeInterval: 1.0/Double(frameRate), repeats: true) { [weak self] timer in
                guard let self = self, let dice = self.dice else {
                    timer.invalidate()
                    return
                }

                progress += increment

                if progress >= 1.0 {
                    dice.position = targetPos
                    dice.transform.rotation = targetRotation
                    timer.invalidate()
                    self.recenterTimer = nil
                    print("Recenter and orient animation completed")
                    completion?()
                } else {
                    let eased = progress * progress * (3.0 - 2.0 * progress)
                    dice.position = startPos + (targetPos - startPos) * eased
                    let q = simd_slerp(startRotation, targetRotation, eased)
                    dice.transform.rotation = q
                }
            }
        }
        
        private func cancelRecenterTimer() {
            recenterTimer?.invalidate()
            recenterTimer = nil
            if isRecentering {
                isRecentering = false
                print("Recenter animation cancelled")
            }
        }
        
        func onFaceCountChanged() {
            cancelRecenterTimer()
            isRecentering = false
            awaitingResult = false
            hasAnnouncedResult = false

            guard let anchor = anchor else { return }

            // Preserve transform if an old die exists
            let oldTransform = dice?.transform
            // Remove old die
            dice?.removeFromParent()

            // Create new die for the selected face count
            let newDie = makeDie?(faceCount) ?? ModelEntity()
            if let t = oldTransform {
                newDie.transform = t
            } else {
                newDie.position = [0, 0, playPlaneZ]
            }

            anchor.addChild(newDie)
            dice = newDie

            // Small pulse to indicate change, then auto-roll
            let original = newDie.scale
            let up = SIMD3<Float>(repeating: 1.06)
            var tVal: Float = 0
            let duration: Float = 0.15
            let frameRate: Float = 60
            let step = 1.0 / (duration * frameRate)
            Timer.scheduledTimer(withTimeInterval: 1.0/Double(frameRate), repeats: true) { timer in
                tVal += step
                if tVal >= 1.0 {
                    newDie.scale = original
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.rollDice()
                    }
                } else {
                    let p = tVal * tVal * (3 - 2 * tVal)
                    if tVal < 0.5 {
                        let q = p * 2
                        newDie.scale = original + (up - original) * q
                    } else {
                        let q = (1 - p) * 2
                        newDie.scale = original + (up - original) * max(0, q)
                    }
                }
            }
        }
        
        func rollDice() {
            guard let dice = dice else { return }
            awaitingResult = true
            hasAnnouncedResult = false
            // Cancel any ongoing recentering animation
            cancelRecenterTimer()
            // Reset recentering state when user interacts
            isRecentering = false
            settleTimer = 0
            recenterCooldown = 0
            // Ensure dice is in dynamic mode for physics interactions
            let physicsMaterial = PhysicsMaterialResource.generate(
                staticFriction: 0.3,
                dynamicFriction: 0.2,
                restitution: 0.6
            )
            dice.components.set(PhysicsBodyComponent(
                massProperties: .default,
                material: physicsMaterial,
                mode: .dynamic
            ))
            // Ensure motion component exists after resetting physics body
            if dice.components[PhysicsMotionComponent.self] == nil {
                dice.components.set(PhysicsMotionComponent())
            }
            if var body = dice.components[PhysicsBodyComponent.self] {
                body.linearDamping = 0.02
                body.angularDamping = 0.02
                dice.components.set(body)
            }
            // Impulses
            let randomX = Float.random(in: -0.08...0.08)
            let randomY = Float.random(in: 0.15...0.3)
            let randomZ = Float.random(in: -0.08...0.08)
            dice.applyLinearImpulse([randomX, randomY, randomZ], relativeTo: nil)
            let randomAngular = SIMD3<Float>(Float.random(in: -3...3), Float.random(in: -3...3), Float.random(in: -3...3))
            dice.applyAngularImpulse(randomAngular, relativeTo: nil)
            print("Dice roll triggered")
            startRollingHaptics()
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.view != nil else { return }
            rollDice()
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let dice = dice, let view = gesture.view else { return }
            
            let location = gesture.translation(in: view)
            
            let rotationX = Float(location.y) * 0.01
            let rotationY = Float(location.x) * 0.01
            
            dice.transform.rotation *= simd_quatf(angle: rotationY, axis: [0, 1, 0])
            dice.transform.rotation *= simd_quatf(angle: rotationX, axis: [1, 0, 0])
            
            if gesture.state == .ended {
                gesture.setTranslation(.zero, in: view)
            }
        }
        
        func installOrUpdateBoundaries(in arView: ARView, on anchor: AnchorEntity) {
            let screenSize = arView.bounds.size
            guard screenSize.width > 0, screenSize.height > 0 else { return }
            let aspect = Float(screenSize.width / screenSize.height)
            
            // Area di gioco molto più grande - copre tutto lo schermo
            let depth: Float = 1.5  // Aumentato da 0.6
            let width: Float = depth * aspect  // Rimosso il moltiplicatore 0.8
            
            // Remove old entities
            wallEntities.forEach { $0.removeFromParent() }
            wallEntities.removeAll()
            if let floorEntity = floorEntity { floorEntity.removeFromParent() }
            
            // Crea il pavimento
            let floor = makeFloor?(width, depth, playPlaneZ) ?? ModelEntity()
            anchor.addChild(floor)
            floorEntity = floor
            
            // Muri INVISIBILI - ModelEntity senza materiale visibile
            let physicsMaterial = PhysicsMaterialResource.generate(
                staticFriction: 0.02,
                dynamicFriction: 0.02,
                restitution: 0.9
            )
            
            let halfW = width / 2
            let halfD = depth / 2
            let wallHeight: Float = 0.5
            
            // Front wall (near camera)
            let front = ModelEntity()
            front.position = [0, wallHeight/2, playPlaneZ + halfD]
            front.components.set(PhysicsBodyComponent(
                massProperties: .default,
                material: physicsMaterial,
                mode: .static
            ))
            front.collision = CollisionComponent(
                shapes: [.generateBox(width: width, height: wallHeight, depth: sideThickness)]
            )
            
            // Back wall
            let back = ModelEntity()
            back.position = [0, wallHeight/2, playPlaneZ - halfD]
            back.components.set(PhysicsBodyComponent(
                massProperties: .default,
                material: physicsMaterial,
                mode: .static
            ))
            back.collision = CollisionComponent(
                shapes: [.generateBox(width: width, height: wallHeight, depth: sideThickness)]
            )
            
            // Left wall
            let left = ModelEntity()
            left.position = [-halfW, wallHeight/2, playPlaneZ]
            left.components.set(PhysicsBodyComponent(
                massProperties: .default,
                material: physicsMaterial,
                mode: .static
            ))
            left.collision = CollisionComponent(
                shapes: [.generateBox(width: sideThickness, height: wallHeight, depth: depth)]
            )
            
            // Right wall
            let right = ModelEntity()
            right.position = [halfW, wallHeight/2, playPlaneZ]
            right.components.set(PhysicsBodyComponent(
                massProperties: .default,
                material: physicsMaterial,
                mode: .static
            ))
            right.collision = CollisionComponent(
                shapes: [.generateBox(width: sideThickness, height: wallHeight, depth: depth)]
            )
            
            // Top wall (ceiling)
            let top = ModelEntity()
            top.position = [0, 0.3, playPlaneZ]
            top.components.set(PhysicsBodyComponent(
                massProperties: .default,
                material: physicsMaterial,
                mode: .static
            ))
            top.collision = CollisionComponent(
                shapes: [.generateBox(width: width, height: sideThickness, depth: depth)]
            )
            
            // Aggiungi i muri invisibili
            [front, back, left, right, top].forEach { wall in
                anchor.addChild(wall)
                wallEntities.append(wall)
            }
            
            // After first successful installation, enable physics on the dice
            if !installed {
                installed = true
                if let dice = self.dice {
                    // Place the dice slightly above the floor and enable dynamics
                    var newPos = dice.position
                    newPos.y = max(newPos.y, 0.08)
                    dice.position = newPos
                    if var body = dice.components[PhysicsBodyComponent.self] {
                        body.mode = .dynamic
                        dice.components.set(body)
                    }
                    if var motion = dice.components[PhysicsMotionComponent.self] {
                        motion.linearVelocity = .zero
                        motion.angularVelocity = .zero
                        dice.components.set(motion)
                    }
                }
            }
        }
    }
}

// Fireworks overlay using CAEmitterLayer, positioned in screen space
final class FireworksOverlay: UIView {
    private var activeEmitters: [CAEmitterLayer] = []
    private var stopTimers: [Timer] = []
    
    private let maxActiveEmitters = 4
    private var lastExplosionTime: TimeInterval = 0
    private let minExplosionInterval: TimeInterval = 0.5
    
    deinit {
        stopTimers.forEach { $0.invalidate() }
        activeEmitters.forEach { $0.removeFromSuperlayer() }
        activeEmitters.removeAll()
    }

    func explode(at point: CGPoint, duration: TimeInterval) {
        // Throttle explosions to avoid overload
        let now = CACurrentMediaTime()
        if now - lastExplosionTime < minExplosionInterval { return }
        lastExplosionTime = now

        // Cap the number of active emitters
        if activeEmitters.count >= maxActiveEmitters {
            if let oldest = activeEmitters.first {
                oldest.birthRate = 0
                oldest.emitterCells = nil
                oldest.removeFromSuperlayer()
                activeEmitters.removeFirst()
            }
        }
        
        // Create a rocket emitter at the given point
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = point
        emitter.emitterShape = .point
        emitter.renderMode = .additive
        emitter.zPosition = 0 // stays visually behind overlays; AR content is underneath anyway

        // Rocket cell (rises up then bursts)
        let rocket = CAEmitterCell()
        rocket.birthRate = 1
        rocket.lifetime = 1.0
        rocket.velocity = 180
        rocket.velocityRange = 60
        rocket.emissionLongitude = -.pi/2 // shoot upward
        rocket.emissionRange = .pi/12
        rocket.yAcceleration = -90 // fight gravity to go up (UIKit y+ is down)
        rocket.color = UIColor.white.cgColor
        rocket.redRange = 0.8
        rocket.greenRange = 0.8
        rocket.blueRange = 0.8
        rocket.alphaSpeed = -0.45
        rocket.scale = 0.5
        rocket.spin = 1.0

        // Burst cell (brief flash before sparks)
        let burst = CAEmitterCell()
        burst.birthRate = 1
        burst.lifetime = 0.25
        burst.scale = 1.1
        burst.color = UIColor.white.cgColor

        // Spark cells (actual fireworks fragments)
        let spark = CAEmitterCell()
        spark.birthRate = 160
        spark.lifetime = 1.6
        spark.velocity = 150
        spark.velocityRange = 100
        spark.emissionRange = .pi * 2
        spark.yAcceleration = 70
        spark.scale = 0.55
        spark.scaleRange = 0.25
        spark.alphaSpeed = -0.5
        spark.spin = 2.0
        spark.spinRange = 3.0
        spark.contents = makeSparkImage().cgImage
        spark.color = UIColor.white.cgColor
        spark.redRange = 1.0
        spark.greenRange = 1.0
        spark.blueRange = 1.0

        // Chain: rocket -> burst -> spark
        burst.emitterCells = [spark]
        rocket.emitterCells = [burst]
        emitter.emitterCells = [rocket]

        layer.addSublayer(emitter)
        activeEmitters.append(emitter)

        // Stop after duration
        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self, weak emitter] _ in
            guard let self = self, let emitter = emitter else { return }
            emitter.birthRate = 0
            emitter.emitterCells = nil
            emitter.removeFromSuperlayer()
            self.activeEmitters.removeAll { $0 == emitter }
        }
        stopTimers.append(timer)

        // Removed the scheduled additional bursts to avoid cascades
    }

    private func makeSparkImage() -> UIImage {
        let size = CGSize(width: 6, height: 6)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        let ctx = UIGraphicsGetCurrentContext()!
        let rect = CGRect(origin: .zero, size: size)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: rect)
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }
}

struct CustomizeSheet: View {
    @Binding var faceCount: Int
    private let options = Array(3...12)

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Number of faces")) {
                    Picker("Faces", selection: $faceCount) {
                        ForEach(options, id: \.self) { n in
                            Text("\(n) faces").tag(n)
                        }
                    }
                }
                Section(footer: Text("Al momento la forma fisica resta un cubo; il risultato rispetta il numero di facce selezionato. Possiamo aggiungere forme personalizzate in un secondo passaggio.")) {
                    EmptyView()
                }
            }
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    DiceView()
}
