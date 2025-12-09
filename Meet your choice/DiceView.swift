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
            Color.black.ignoresSafeArea(.all)
            
            DiceViewContainer(faceCount: faceCount, onResult: { number in
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    lastResult = number
                }
                // Show the winner text for 3 seconds (same duration as fireworks)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        lastResult = nil
                    }
                }
            }, onRollStart: {
                // Hide the winner message immediately when a new roll starts
                withAnimation(.easeOut(duration: 0.2)) {
                    lastResult = nil
                }
            })
            .ignoresSafeArea(.all)

            if let number = lastResult {
                VStack {
                    Spacer()
                    VStack(spacing: 16) {
                        Text("The winner is:")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(.white)
                        
                        HStack(spacing: 12) {
                            // Show the winning face
                            WinningFaceView(number: number, faceCount: faceCount)
                                .frame(width: 60, height: 60)
                            
                            // Display result based on face count
                            if faceCount == 2 {
                                Text(number == 1 ? "Cross" : "Head")
                                    .font(.system(size: 36, weight: .bold))
                                    .foregroundColor(.white)
                            } else {
                                Text("d\(faceCount): \(number)")
                                    .font(.system(size: 36, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        showCustomize = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 16, weight: .medium))
                            Text("Customize")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(.white.opacity(0.2), lineWidth: 1)
                                )
                        )
                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .buttonStyle(CustomizeButtonStyle())
                    .padding([.top, .trailing], 20)
                }
                Spacer()
            }
            .sheet(isPresented: $showCustomize) {
                CustomizeSheet(faceCount: $faceCount)
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct DiceViewContainer: UIViewRepresentable {
    var faceCount: Int = 6
    var onResult: ((Int) -> Void)? = nil
    var onRollStart: (() -> Void)? = nil
    private let playPlaneZ: Float = -0.5
    private var sideThickness: Float { 0.02 }
    
    func makeUIView(context: Context) -> ARView {
        let arView = ShakeARView(frame: .zero)
        
        // Set background color (black)
        arView.environment.background = .color(.black)
        
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
        dice.position = [0, 0.25, -0.5] // Start well above the floor (adjusted for larger size)
        anchor.addChild(dice)
        print("Dice created at position: \(dice.position)")
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
        context.coordinator.onRollStart = onRollStart
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
        if faces == 2 {
            return createCoinDie()
        } else if faces == 12 {
            return createDodecahedronDie()
        }
        // Default: dado a 6 facce
        let size: Float = 0.15
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
                // Fallback: solid white face if texture generation fails
                mat.color = .init(tint: .white)
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
    
    func addLighting(to anchor: AnchorEntity) {
        // Add directional light
        let directionalLight = DirectionalLightComponent(
            color: .white,
            intensity: 500,
            isRealWorldProxy: false
        )
        
        let lightEntity = Entity()
        lightEntity.components.set(directionalLight)
        lightEntity.position = [0.5, 1, 0.5]
        lightEntity.look(at: [0, 0, 0], from: lightEntity.position, relativeTo: nil)
        
        anchor.addChild(lightEntity)
    }
    
    func createFloor(width: Float, depth: Float, z: Float) -> ModelEntity {
        // Create a simple box as floor instead of a rotated plane
        let floorMesh = MeshResource.generateBox(width: width, height: 0.02, depth: depth)
        
        var floorMaterial = SimpleMaterial()
        floorMaterial.color = .init(tint: .black) // Floor nero
        floorMaterial.roughness = 0.8
        floorMaterial.metallic = 0.0
        
        let floor = ModelEntity(mesh: floorMesh, materials: [floorMaterial])
        // Position the floor at Y = -0.01 (half thickness below zero) and at the specified z
        floor.position = [0, -0.01, z]
        
        // Physics for the floor
        let physicsMaterial = PhysicsMaterialResource.generate(
            staticFriction: 0.8,
            dynamicFriction: 0.6,
            restitution: 0.3
        )
        
        floor.components.set(PhysicsBodyComponent(
            massProperties: .default,
            material: physicsMaterial,
            mode: .static
        ))
        
        // Simple box collision that matches the mesh exactly
        floor.collision = CollisionComponent(
            shapes: [.generateBox(width: width, height: 0.02, depth: depth)]
        )
        
        print("📦 Floor created at position: \(floor.position), size: \(width)x0.02x\(depth)")
        print("📦 Expected dice rest Y: 0.075 (floor top 0 + dice half 0.075)")
        
        return floor
    }
    
    func createCoinDie() -> ModelEntity {
        // Thin cylinder acting as a 2-sided die (coin)
        let radius: Float = 0.11 // Aumentato per essere proporzionale al dado più grande
        let thickness: Float = 0.025
        let epsilon: Float = 0.0015

        // Base cylinder
        let baseMesh = MeshResource.generateCylinder(height: thickness, radius: radius)
        var baseMaterial = SimpleMaterial()
        baseMaterial.color = .init(tint: .white) // Moneta bianca
        let coin = ModelEntity(mesh: baseMesh, materials: [baseMaterial])

        // Top overlay (face 2) — oriented upward (+Y)
        let planeMesh = MeshResource.generatePlane(width: radius * 1.75, depth: radius * 1.75)
        do {
            var topMat = SimpleMaterial()
            if let cg = createCoinFaceTexture(heads: true),
               let tex = try? TextureResource(image: cg, options: .init(semantic: .color)) {
                topMat.color = .init(tint: .white, texture: .init(tex))
                topMat.faceCulling = .none
            } else {
                topMat.color = .init(tint: .white)
                topMat.faceCulling = .none
            }
            let top = ModelEntity(mesh: planeMesh, materials: [topMat])
            top.position = [0, thickness / 2 + epsilon, 0]
            top.orientation = simd_quatf(angle: 0, axis: [1, 0, 0])
            coin.addChild(top)
        }

        // Bottom overlay (face 1) — oriented downward (-Y)
        do {
            var bottomMat = SimpleMaterial()
            if let cg = createCoinFaceTexture(heads: false),
               let tex = try? TextureResource(image: cg, options: .init(semantic: .color)) {
                bottomMat.color = .init(tint: .white, texture: .init(tex))
                bottomMat.faceCulling = .none
            } else {
                bottomMat.color = .init(tint: .white)
                bottomMat.faceCulling = .none
            }
            let bottom = ModelEntity(mesh: planeMesh, materials: [bottomMat])
            bottom.position = [0, -thickness / 2 - epsilon, 0]
            bottom.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])
            coin.addChild(bottom)
        }

        // Physics and collision
        let physicsMaterial = PhysicsMaterialResource.generate(
            staticFriction: 0.05,
            dynamicFriction: 0.03,
            restitution: 0.9
        )
        coin.components.set(PhysicsBodyComponent(
            massProperties: .default,
            material: physicsMaterial,
            mode: .dynamic
        ))
        if coin.components[PhysicsMotionComponent.self] == nil {
            coin.components.set(PhysicsMotionComponent())
        }
        if var body = coin.components[PhysicsBodyComponent.self] {
            body.linearDamping = 0.02
            body.angularDamping = 0.02
            coin.components.set(body)
        }
        // Collision: try convex from the cylinder mesh; fallback to box
        do {
            let shape = try ShapeResource.generateConvex(from: baseMesh)
            coin.collision = CollisionComponent(shapes: [shape])
        } catch {
            coin.collision = CollisionComponent(shapes: [.generateBox(size: [radius * 2, thickness, radius * 2])])
        }

        return coin
    }
    
    func createDodecahedronDie() -> ModelEntity {
        // Dodecaedro regolare (12 facce pentagonali)
        let phi: Float = (1.0 + sqrt(5.0)) / 2.0 // rapporto aureo
        let scale: Float = 0.08 // Scala per dimensione appropriata
        
        // Vertici del dodecaedro (coordinate normalizzate)
        let vertices: [SIMD3<Float>] = [
            SIMD3<Float>(1, 1, 1),
            SIMD3<Float>(1, 1, -1),
            SIMD3<Float>(1, -1, 1),
            SIMD3<Float>(1, -1, -1),
            SIMD3<Float>(-1, 1, 1),
            SIMD3<Float>(-1, 1, -1),
            SIMD3<Float>(-1, -1, 1),
            SIMD3<Float>(-1, -1, -1),
            SIMD3<Float>(0, phi, 1/phi),
            SIMD3<Float>(0, phi, -1/phi),
            SIMD3<Float>(0, -phi, 1/phi),
            SIMD3<Float>(0, -phi, -1/phi),
            SIMD3<Float>(1/phi, 0, phi),
            SIMD3<Float>(-1/phi, 0, phi),
            SIMD3<Float>(1/phi, 0, -phi),
            SIMD3<Float>(-1/phi, 0, -phi),
            SIMD3<Float>(phi, 1/phi, 0),
            SIMD3<Float>(phi, -1/phi, 0),
            SIMD3<Float>(-phi, 1/phi, 0),
            SIMD3<Float>(-phi, -1/phi, 0)
        ].map { $0 * scale }
        
        // Le 12 facce pentagonali (indici dei vertici)
        let faces: [[Int]] = [
            [0, 8, 9, 1, 16],
            [0, 12, 13, 4, 8],
            [0, 16, 17, 2, 12],
            [1, 9, 5, 15, 14],
            [1, 14, 3, 17, 16],
            [2, 10, 11, 3, 17],
            [2, 12, 13, 6, 10],
            [3, 11, 7, 15, 14],
            [4, 8, 9, 5, 18],
            [4, 13, 6, 19, 18],
            [5, 9, 8, 4, 18],
            [6, 10, 11, 7, 19]
        ]
        
        var descriptor = MeshDescriptor()
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        
        // Converti ogni pentagono in triangoli
        for face in faces {
            let center = face.reduce(SIMD3<Float>(0,0,0)) { $0 + vertices[$1] } / Float(face.count)
            let normal = normalize(cross(vertices[face[1]] - vertices[face[0]], vertices[face[2]] - vertices[face[0]]))
            
            for i in 0..<face.count {
                let next = (i + 1) % face.count
                let base = UInt32(positions.count)
                
                positions.append(vertices[face[i]])
                positions.append(vertices[face[next]])
                positions.append(center)
                
                normals.append(contentsOf: [normal, normal, normal])
                indices.append(contentsOf: [base, base + 1, base + 2])
            }
        }
        
        descriptor.positions = .init(positions)
        descriptor.normals = .init(normals)
        descriptor.primitives = .triangles(indices)
        
        let mesh: MeshResource
        do {
            mesh = try MeshResource.generate(from: [descriptor])
        } catch {
            return createDice(for: 6) // Fallback
        }
        
        var material = SimpleMaterial()
        material.color = .init(tint: .white) // Dodecaedro bianco
        let die = ModelEntity(mesh: mesh, materials: [material])
        
        // Physics setup
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
            die.collision = CollisionComponent(shapes: [.generateBox(size: [scale * 4, scale * 4, scale * 4])])
        }
        
        return die
    }

    func createDiceFaceTexture(number: Int) -> CGImage? {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)

        let image = renderer.image { context in
            // Background: white (dado bianco)
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Draw black pips (puntini neri su sfondo bianco)
            let cg = context.cgContext
            cg.setShouldAntialias(true)
            cg.setFillColor(UIColor.black.cgColor)

            // Reasonable radius for 512x512
            let dotRadius: CGFloat = size.width * 0.085
            drawDots(for: number, in: cg, size: size, dotRadius: dotRadius)
        }

        return image.cgImage
    }
    
    func createCoinFaceTexture(heads: Bool) -> CGImage? {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            cg.setShouldAntialias(true)

            // Background bianco
            UIColor.white.setFill()
            cg.fillEllipse(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))

            // Coin rim
            cg.setStrokeColor(UIColor(white: 0.7, alpha: 1.0).cgColor)
            cg.setLineWidth(14)
            cg.strokeEllipse(in: CGRect(x: 7, y: 7, width: size.width - 14, height: size.height - 14))

            // Inner rim
            cg.setStrokeColor(UIColor(white: 0.5, alpha: 1.0).cgColor)
            cg.setLineWidth(4)
            cg.strokeEllipse(in: CGRect(x: 28, y: 28, width: size.width - 56, height: size.height - 56))

            // Text label (TESTA / CROCE) - nero
            let text = heads ? "Head" : "Cross"
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 120, weight: .black),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph,
                .kern: 2
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            var bounds = attributed.boundingRect(with: CGSize(width: size.width - 80, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            bounds.origin.x = (size.width - bounds.width) / 2
            bounds.origin.y = (size.height - bounds.height) / 2
            attributed.draw(in: bounds)
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
        var onRollStart: (() -> Void)?
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
        private var totalStillTimer: TimeInterval = 0 // Track total time dice has been still
        private var isRecentering: Bool = false
        private var recenterCooldown: TimeInterval = 0
        private var recenterTimer: Timer?
        
        private var lastPosition: SIMD3<Float>?
        private var lastRotation: simd_quatf?
        
        private var hapticEngine: CHHapticEngine?
        private var hasAnnouncedResult: Bool = false
        private var awaitingResult: Bool = false
        
        private var lastCollisionTime: TimeInterval = 0
        
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

        private func playStartHaptic() {
            // Haptic all'inizio del lancio
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }

        private func playCollisionHaptic() {
            // Haptic quando sbatte contro i muri
            let now = CACurrentMediaTime()
            // Evita troppi haptics ravvicinati
            guard now - lastCollisionTime > 0.2 else { return }
            lastCollisionTime = now
            
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }

        private func playStopHaptic() {
            // Haptic quando si ferma
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
        
        private func playCelebrationHaptic() {
            // Sequenza di haptic per la celebrazione (3 secondi totali)
            let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
            let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
            let lightGenerator = UIImpactFeedbackGenerator(style: .light)
            
            // Prepara i generatori
            heavyGenerator.prepare()
            mediumGenerator.prepare()
            lightGenerator.prepare()
            
            // Sequenza di celebrazione ridotta
            DispatchQueue.main.asyncAfter(deadline: .now()) {
                heavyGenerator.impactOccurred()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                mediumGenerator.impactOccurred()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                lightGenerator.impactOccurred()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                heavyGenerator.impactOccurred()
            }
            
            // Se il dispositivo supporta haptics avanzati, usa anche quello
            if let hapticEngine = hapticEngine {
                playAdvancedCelebrationHaptic(engine: hapticEngine)
            }
        }
        
        private func playAdvancedCelebrationHaptic(engine: CHHapticEngine) {
            // Pattern haptic avanzato per la celebrazione (ridotto a 0.6 secondi)
            do {
                let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
                
                var events: [CHHapticEvent] = []
                
                // Pattern di celebrazione ridotto
                let timings: [TimeInterval] = [0.0, 0.1, 0.2, 0.3, 0.4, 0.6]
                let intensities: [Float] = [1.0, 0.8, 0.6, 0.9, 0.7, 0.5]
                
                for (index, timing) in timings.enumerated() {
                    let intensityParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensities[index])
                    let sharpnessParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                    
                    let event = CHHapticEvent(
                        eventType: .hapticTransient,
                        parameters: [intensityParam, sharpnessParam],
                        relativeTime: timing
                    )
                    events.append(event)
                }
                
                let pattern = try CHHapticPattern(events: events, parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: 0)
                
            } catch {
                print("Errore nella creazione del pattern haptic avanzato: \(error)")
            }
        }
        
        func startObservingSceneUpdates() {
            guard let arView = arView else { return }
            setupHaptics()
            sceneUpdateCancellable?.cancel()
            
            // Subscribe to scene updates
            let sceneSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                self?.handleSceneUpdate(event)
            }
            
            // Subscribe to collisions (separate subscription)
            let collisionSubscription = arView.scene.subscribe(to: CollisionEvents.Began.self) { [weak self] collision in
                self?.handleCollision(collision)
            }
            
            // Store both subscriptions
            sceneUpdateCancellable = AnyCancellable {
                sceneSubscription.cancel()
                collisionSubscription.cancel()
            }
        }
        
        private func handleCollision(_ event: CollisionEvents.Began) {
            // Verifica se il dado ha colpito un muro
            guard let dice = dice else { return }
            if event.entityA == dice || event.entityB == dice {
                playCollisionHaptic()
            }
        }
        
        private func handleSceneUpdate(_ event: SceneEvents.Update) {
            guard let dice = dice else { return }
            
            // Cooldown to avoid repeated recenters
            if recenterCooldown > 0 {
                recenterCooldown -= event.deltaTime
            }
            
            // Read physics motion state
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
            
            // Compute vertical speed
            var verticalSpeedAbs: Float = 0
            if let motion = dice.components[PhysicsMotionComponent.self] {
                verticalSpeedAbs = abs(motion.linearVelocity.y)
            } else if let lastPos = lastPosition, event.deltaTime > 0 {
                verticalSpeedAbs = abs((dice.position.y - lastPos.y) / Float(event.deltaTime))
            }
            
            // Consider near-floor when y is close to expected resting height (adjusted for larger die)
            // Il dado ha size 0.15, quindi half = 0.075. Floor è a y=-0.01, quindi il dado a riposo è a y=0.075-0.01=0.065
            let expectedRestY: Float = 0.075
            let nearFloor = dice.position.y < 0.15 // More lenient floor detection
            
            // Debug logging for troubleshooting
            if linearSpeed < 0.03 && angularSpeed < 0.12 && !nearFloor {
                print("⚠️ Dice appears still but not near floor! Y: \(String(format: "%.4f", dice.position.y)), Linear: \(String(format: "%.4f", linearSpeed)), Angular: \(String(format: "%.4f", angularSpeed))")
            }
            
            // Determine moving state - more lenient thresholds
            let movingThresholdLinear: Float = 0.03
            let movingThresholdAngular: Float = 0.15
            let isMoving = (linearSpeed > movingThresholdLinear) || (angularSpeed > movingThresholdAngular)
            
            if isMoving {
                hasAnnouncedResult = false
                totalStillTimer = 0 // Reset backup timer when moving
                // Quando il dado si muove, aspettiamo un nuovo risultato
                if !awaitingResult {
                    awaitingResult = true
                }
            } else {
                // Dice is not moving, increment backup timer
                totalStillTimer += event.deltaTime
            }
            
            // More lenient thresholds for considering the dice as settled
            let linearThreshold: Float = 0.025
            let angularThreshold: Float = 0.12
            let verticalThreshold: Float = 0.03
            
            let isSettled = linearSpeed < linearThreshold && angularSpeed < angularThreshold && verticalSpeedAbs < verticalThreshold && nearFloor
            
            if isSettled && !isRecentering && recenterCooldown <= 0 {
                settleTimer += event.deltaTime
                
                // Log ogni mezzo secondo mentre aspetta
                if Int(settleTimer * 10) % 5 == 0 && settleTimer > 0.1 {
                    print("Dice settling... timer: \(String(format: "%.2f", settleTimer))s, Linear: \(String(format: "%.4f", linearSpeed)), Angular: \(String(format: "%.4f", angularSpeed))")
                }
                
                // Dopo 0.4 secondi di stabilità (ridotto da 0.6), inizia il recenter
                if settleTimer > 0.4 {
                    print("✅ Dice settled for 0.4s, starting recenter. hasAnnounced: \(hasAnnouncedResult), awaiting: \(awaitingResult)")
                    startRecenterAndShowResult()
                }
            } else {
                // Reset timer se il dado si muove di nuovo
                if !isSettled {
                    if settleTimer > 0 {
                        print("❌ Dice moved again, resetting settle timer (was at \(String(format: "%.2f", settleTimer))s)")
                    }
                    settleTimer = 0
                }
                if !isRecentering {
                    cancelRecenterTimer()
                }
                
                // Backup: force recenter if dice has been still for too long (even if not "settled")
                if !isMoving && totalStillTimer > 2.0 && !isRecentering && recenterCooldown <= 0 {
                    print("🔧 BACKUP: Forcing recenter after \(String(format: "%.2f", totalStillTimer))s of stillness")
                    print("    Y position: \(String(format: "%.4f", dice.position.y)), nearFloor: \(nearFloor)")
                    startRecenterAndShowResult()
                    totalStillTimer = 0
                }
            }
            
            // Log periodico dello stato
            if settleTimer == 0 && linearSpeed > 0.001 {
                // Log solo occasionalmente quando il dado si muove
                if Int(dice.position.x * 100) % 10 == 0 {
                    print("Moving - Linear: \(String(format: "%.4f", linearSpeed)), Angular: \(String(format: "%.4f", angularSpeed)), Y: \(String(format: "%.3f", dice.position.y)), NearFloor: \(nearFloor)")
                }
            }
            
            lastPosition = dice.position
            lastRotation = dice.transform.rotation
        }
        
        private func determineTopFace() -> (number: Int, faceOrientation: simd_quatf)? {
            guard let dice = dice else { return nil }
            let q = dice.transform.rotation
            let worldUp = SIMD3<Float>(0, 1, 0)

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

        private func targetRotationForTop(number: Int) -> simd_quatf {
            switch number {
            case 6:
                return simd_quatf(angle: 0, axis: [0, 1, 0])
            case 1:
                return simd_quatf(angle: .pi, axis: [1, 0, 0])
            case 2:
                return simd_quatf(angle: -.pi/2, axis: [1, 0, 0])
            case 5:
                return simd_quatf(angle:  .pi/2, axis: [1, 0, 0])
            case 3:
                return simd_quatf(angle:  .pi/2, axis: [0, 0, 1])
            case 4:
                return simd_quatf(angle: -.pi/2, axis: [0, 0, 1])
            default:
                return simd_quatf(angle: 0, axis: [0, 1, 0])
            }
        }
        
        private func startRecenterAndShowResult() {
            guard let dice = dice, !isRecentering else {
                print("Cannot start recenter - dice: \(dice != nil), isRecentering: \(isRecentering)")
                return
            }
            
            print("=== STARTING RECENTER ===")
            print("Current position: \(dice.position)")
            print("awaitingResult: \(awaitingResult), hasAnnouncedResult: \(hasAnnouncedResult)")

            let currentPos = dice.position
            let liftedY: Float = max(currentPos.y, 0.1) // Lift a bit higher during animation
            let targetPos = SIMD3<Float>(0, liftedY, playPlaneZ)

            let winningNumber: Int
            let targetRotation: simd_quatf
            if faceCount == 6, let result = determineTopFace() {
                winningNumber = result.number
                targetRotation = targetRotationForTop(number: result.number)
            } else {
                winningNumber = max(1, Int.random(in: 1...max(1, faceCount)))
                targetRotation = dice.transform.rotation
            }

            print("Starting recenter to center with result: \(winningNumber)")

            isRecentering = true
            recenterCooldown = 5.0

            if var body = dice.components[PhysicsBodyComponent.self] {
                body.mode = .kinematic
                dice.components.set(body)
            }

            animateDiceToCenter(to: targetPos, targetRotation: targetRotation) { [weak self] in
                guard let self = self, let dice = self.dice else { return }

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

                        // Il dado dovrebbe riposare a y = 0.075 (metà dimensione 0.15/2 sopra il floor a -0.01)
                        dice.position.y = 0.075

                        if var body = dice.components[PhysicsBodyComponent.self] {
                            body.mode = .dynamic
                            dice.components.set(body)
                        }

                        if var motion = dice.components[PhysicsMotionComponent.self] {
                            motion.linearVelocity = .zero
                            motion.angularVelocity = .zero
                            dice.components.set(motion)
                        }

                        // Mostra sempre il risultato quando il dado si stabilizza
                        if self.awaitingResult && !self.hasAnnouncedResult {
                            self.onResult?(winningNumber)
                            if let arView = self.arView {
                                let worldPos = dice.position(relativeTo: nil)
                                if let screenPoint = arView.project(worldPos) {
                                    self.fireworksView?.explode(at: screenPoint, duration: 3.0) // Ridotto da 8.0 a 3.0 secondi
                                } else {
                                    let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
                                    self.fireworksView?.explode(at: center, duration: 3.0) // Ridotto da 8.0 a 3.0 secondi
                                }
                            }
                            
                            // Haptic prolungato per i coriandoli (celebrazione)
                            self.playCelebrationHaptic()
                            
                            self.hasAnnouncedResult = true
                            self.awaitingResult = false
                        }
                        
                        self.isRecentering = false
                    } else {
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
            settleTimer = 0
            totalStillTimer = 0 // Reset backup timer

            guard let anchor = anchor else { return }

            let oldTransform = dice?.transform
            dice?.removeFromParent()

            let newDie = makeDie?(faceCount) ?? ModelEntity()
            if let t = oldTransform {
                newDie.transform = t
            } else {
                newDie.position = [0, 0, playPlaneZ]
            }

            anchor.addChild(newDie)
            dice = newDie

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
            
            print("\n🎲 === ROLL DICE CALLED ===")
            
            // Notify that a new roll is starting (this will hide the winner message)
            onRollStart?()
            
            // Reset di tutti i flag per un nuovo lancio
            awaitingResult = true
            hasAnnouncedResult = false
            cancelRecenterTimer()
            isRecentering = false
            settleTimer = 0
            totalStillTimer = 0 // Reset backup timer
            recenterCooldown = 0
            
            // Assicurati che il dado sia in modalità dinamica
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
            
            if dice.components[PhysicsMotionComponent.self] == nil {
                dice.components.set(PhysicsMotionComponent())
            }
            if var body = dice.components[PhysicsBodyComponent.self] {
                body.linearDamping = 0.02
                body.angularDamping = 0.02
                dice.components.set(body)
            }
            
            // Applica gli impulsi casuali
            let randomX = Float.random(in: -0.12...0.12)
            let randomY = Float.random(in: 0.2...0.35)
            let randomZ = Float.random(in: -0.12...0.12)
            dice.applyLinearImpulse([randomX, randomY, randomZ], relativeTo: nil)
            
            let randomAngular = SIMD3<Float>(
                Float.random(in: -4...4),
                Float.random(in: -4...4),
                Float.random(in: -4...4)
            )
            dice.applyAngularImpulse(randomAngular, relativeTo: nil)
            
            print("Dice roll triggered (shake or tap)")
            
            // Haptic all'inizio del lancio
            playStartHaptic()
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
            
            let depth: Float = 1.5
            let width: Float = depth * aspect
            
            wallEntities.forEach { $0.removeFromParent() }
            wallEntities.removeAll()
            if let floorEntity = floorEntity { floorEntity.removeFromParent() }
            
            let floor = makeFloor?(width, depth, playPlaneZ) ?? ModelEntity()
            anchor.addChild(floor)
            floorEntity = floor
            
            let physicsMaterial = PhysicsMaterialResource.generate(
                staticFriction: 0.02,
                dynamicFriction: 0.02,
                restitution: 0.9
            )
            
            let halfW = width / 2
            let halfD = depth / 2
            let wallHeight: Float = 0.5
            
            // Front wall
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
            
            // Top wall
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
            
            [front, back, left, right, top].forEach { wall in
                anchor.addChild(wall)
                wallEntities.append(wall)
            }
            
            if !installed {
                installed = true
                if let dice = self.dice {
                    var newPos = dice.position
                    newPos.y = max(newPos.y, 0.2) // Adjusted for larger die
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
                    print("Dice enabled at position: \(dice.position)")
                }
            }
        }
    }
}

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
        let now = CACurrentMediaTime()
        if now - lastExplosionTime < minExplosionInterval { return }
        lastExplosionTime = now

        if activeEmitters.count >= maxActiveEmitters {
            if let oldest = activeEmitters.first {
                oldest.birthRate = 0
                oldest.emitterCells = nil
                oldest.removeFromSuperlayer()
                activeEmitters.removeFirst()
            }
        }
        
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = point
        emitter.emitterShape = .point
        emitter.renderMode = .additive
        emitter.zPosition = 0

        let rocket = CAEmitterCell()
        rocket.birthRate = 2 // Aumentato da 1 a 2 per più razzi
        rocket.lifetime = 1.0 // Ridotto da 1.5 a 1.0
        rocket.velocity = 200 // Ridotto da 220 a 200
        rocket.velocityRange = 70 // Ridotto da 80 a 70
        rocket.emissionLongitude = -.pi/2
        rocket.emissionRange = .pi/8 // Ridotto leggermente per più precisione
        rocket.yAcceleration = -90
        rocket.color = UIColor.white.cgColor
        rocket.redRange = 0.9 // Aumentato da 0.8 a 0.9
        rocket.greenRange = 0.9 // Aumentato da 0.8 a 0.9
        rocket.blueRange = 0.9 // Aumentato da 0.8 a 0.9
        rocket.alphaSpeed = -0.5 // Aumentato da -0.35 per scomparire prima
        rocket.scale = 0.6 // Aumentato da 0.5 a 0.6
        rocket.spin = 1.2 // Aumentato da 1.0 a 1.2

        let burst = CAEmitterCell()
        burst.birthRate = 1
        burst.lifetime = 0.25 // Ridotto da 0.35 a 0.25
        burst.scale = 1.3 // Aumentato da 1.1 a 1.3
        burst.color = UIColor.white.cgColor

        let spark = CAEmitterCell()
        spark.birthRate = 180 // Ridotto da 200 a 180
        spark.lifetime = 1.5 // Ridotto da 2.2 a 1.5 per durare meno
        spark.velocity = 160 // Ridotto da 180 a 160
        spark.velocityRange = 100 // Ridotto da 120 a 100
        spark.emissionRange = .pi * 2
        spark.yAcceleration = 70 // Aumentato da 60 per caduta più veloce
        spark.scale = 0.65 // Aumentato da 0.55 a 0.65
        spark.scaleRange = 0.35 // Aumentato da 0.25 a 0.35
        spark.alphaSpeed = -0.6 // Aumentato da -0.4 per scomparire prima
        spark.spin = 2.5 // Aumentato da 2.0 a 2.5
        spark.spinRange = 4.0 // Aumentato da 3.0 a 4.0
        spark.contents = makeSparkImage().cgImage
        spark.color = UIColor.white.cgColor
        spark.redRange = 1.0
        spark.greenRange = 1.0
        spark.blueRange = 1.0

        burst.emitterCells = [spark]
        rocket.emitterCells = [burst]
        emitter.emitterCells = [rocket]

        layer.addSublayer(emitter)
        activeEmitters.append(emitter)

        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self, weak emitter] _ in
            guard let self = self, let emitter = emitter else { return }
            emitter.birthRate = 0
            emitter.emitterCells = nil
            emitter.removeFromSuperlayer()
            self.activeEmitters.removeAll { $0 == emitter }
        }
        stopTimers.append(timer)
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
    private let options = [2, 6, 12]

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea(.all)
                
                Form {
                    Section(header: Text("Number of faces").foregroundColor(.white)) {
                        Picker("Faces", selection: $faceCount) {
                            ForEach(options, id: \.self) { n in
                                Text("\(n) faces").tag(n)
                            }
                        }
                        .pickerStyle(.segmented)
                        .colorScheme(.dark)
                    }
                    .listRowBackground(Color.clear)
                    
                    Section(footer: Text("Choose the dice you like!").foregroundColor(.gray)) {
                        EmptyView()
                    }
                    .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
                .background(Color.black)
                .navigationTitle("Customize")
                .navigationBarTitleDisplayMode(.inline)
                .preferredColorScheme(.dark)
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct WinningFaceView: View {
    let number: Int
    let faceCount: Int
    
    var body: some View {
        ZStack {
            // Background circle/shape
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            // Content based on face type
            Group {
                if faceCount == 2 {
                    // Coin face
                    coinFaceContent
                } else if faceCount == 12 {
                    // Dodecahedron - just show the number
                    dodecahedronFaceContent
                } else {
                    // Standard 6-sided dice with dots
                    diceFaceContent
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
    
    @ViewBuilder
    private var coinFaceContent: some View {
        VStack(spacing: 2) {
            Text(number == 1 ? "Cross" : "Head")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.black)
                .multilineTextAlignment(.center)
        }
    }
    
    @ViewBuilder
    private var dodecahedronFaceContent: some View {
        Text("\(number)")
            .font(.system(size: 32, weight: .bold))
            .foregroundColor(.black)
    }
    
    @ViewBuilder
    private var diceFaceContent: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let dotRadius = size * 0.08
            let centerX = geometry.size.width / 2
            let centerY = geometry.size.height / 2
            let offset = size * 0.25
            
            ZStack {
                // Draw dots based on the number
                Group {
                    switch number {
                    case 1:
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX, y: centerY)
                    case 2:
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX - offset, y: centerY - offset)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX + offset, y: centerY + offset)
                    case 3:
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX - offset, y: centerY - offset)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX, y: centerY)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX + offset, y: centerY + offset)
                    case 4:
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX - offset, y: centerY - offset)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX + offset, y: centerY - offset)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX - offset, y: centerY + offset)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX + offset, y: centerY + offset)
                    case 5:
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX - offset, y: centerY - offset)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX + offset, y: centerY - offset)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX, y: centerY)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX - offset, y: centerY + offset)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX + offset, y: centerY + offset)
                    case 6:
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX - offset, y: centerY - offset)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX + offset, y: centerY - offset)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX - offset, y: centerY)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX + offset, y: centerY)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX - offset, y: centerY + offset)
                        Circle()
                            .fill(Color.black)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(x: centerX + offset, y: centerY + offset)
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }
}

struct CustomizeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview("Dice App") {
    DiceView()
        .preferredColorScheme(.dark)
}

#Preview("Winning Faces") {
    ZStack {
        Color.black.ignoresSafeArea(.all)
        
        VStack(spacing: 20) {
            Text("6-sided dice faces")
                .font(.headline)
                .foregroundColor(.white)
            HStack(spacing: 15) {
                ForEach(1...6, id: \.self) { number in
                    WinningFaceView(number: number, faceCount: 6)
                        .frame(width: 50, height: 50)
                }
            }
            
            Text("Coin faces")
                .font(.headline)
                .foregroundColor(.white)
            HStack(spacing: 15) {
                WinningFaceView(number: 1, faceCount: 2)
                    .frame(width: 60, height: 60)
                WinningFaceView(number: 2, faceCount: 2)
                    .frame(width: 60, height: 60)
            }
            
            Text("12-sided dice faces")
                .font(.headline)
                .foregroundColor(.white)
            HStack(spacing: 15) {
                ForEach([1, 6, 12], id: \.self) { number in
                    WinningFaceView(number: number, faceCount: 12)
                        .frame(width: 50, height: 50)
                }
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
