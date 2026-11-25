import RealityKit
import SwiftUI

struct WorldSceneView: View {
    let session: WorldSession
    @State private var renderer = WorldRenderer()

    var body: some View {
        // Read observed values in body so incoming simulator updates invalidate the view.
        let revision = session.worldRevision
        let position = session.position
        let heading = session.heading
        RealityView { content in
            content.camera = .virtual
            content.add(renderer.root)
            content.add(renderer.camera)
        } update: { _ in
            _ = revision
            renderer.update(objects: session.objects, position: position, heading: heading)
        }
        .accessibilityLabel("Live region geometry preview with basic primitives and bounds for unsupported objects")
        .accessibilityValue("\(session.objectCount) objects received")
    }
}

@MainActor
private final class WorldRenderer {
    let root = Entity()
    let camera = Entity()
    private let box = MeshResource.generateBox(size: 1)
    private let cylinder = MeshResource.generateCylinder(height: 1, radius: 0.5)
    private let objectMaterial = UnlitMaterial(color: .init(white: 0.65, alpha: 1))
    private let avatarMaterial = UnlitMaterial(color: .systemTeal)
    private var nodes: [UInt32: Entity] = [:]
    private var previous: [UInt32: WorldObject] = [:]

    init() {
        // The simulator is Z-up; RealityKit is Y-up. Keep linksets in simulator coordinates.
        root.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        camera.components.set(PerspectiveCameraComponent(near: 0.1, far: 512, fieldOfViewInDegrees: 65))
    }

    func update(objects: [UInt32: WorldObject], position: SIMD3<Float>, heading: Float) {
        // Bound GPU work in crowded regions. Parent entities are kept even when outside draw distance.
        let visible = Set(objects.values.filter {
            $0.parentID != 0 || simd_distance($0.position, position) < 128
        }.prefix(2000).map(\.id))
        for id in Array(nodes.keys) where !visible.contains(id) {
            nodes.removeValue(forKey: id)?.removeFromParent()
            previous.removeValue(forKey: id)
        }
        for id in visible {
            if nodes[id] == nil {
                let node = Entity()
                let geometry = Entity()
                geometry.name = "geometry"
                node.addChild(geometry)
                nodes[id] = node
            }
        }
        for id in visible {
            guard let object = objects[id], let node = nodes[id] else { continue }
            let parent = object.parentID == 0 ? root : nodes[object.parentID]
            // Ignore malformed cyclic links and hide attachments until their parent arrives.
            var ancestor = object.parentID
            var visited: Set<UInt32> = [id]
            var valid = true
            while ancestor != 0 {
                guard visited.insert(ancestor).inserted, visited.count < 64 else { valid = false; break }
                ancestor = objects[ancestor]?.parentID ?? 0
            }
            guard valid, let parent else { node.isEnabled = false; continue }
            node.isEnabled = true
            if node.parent !== parent { parent.addChild(node) }
            if previous[id] != object {
                node.position = object.position
                node.orientation = simd_normalize(simd_quatf(vector: object.rotation))
                if let geometry = node.findEntity(named: "geometry") {
                    geometry.scale = object.scale
                    if previous[id]?.appearance != object.appearance || geometry.children.isEmpty {
                        for child in Array(geometry.children) { child.removeFromParent() }
                        geometry.addChild(makeGeometry(for: object))
                    }
                }
                previous[id] = object
            }
        }
        let focus = convert(position + SIMD3(0, 0, 1))
        let behind = SIMD3<Float>(-cos(heading) * 8, -sin(heading) * 8, 4)
        camera.look(at: focus, from: convert(position + behind), relativeTo: nil)
    }

    private func makeGeometry(for object: WorldObject) -> Entity {
        let primitive = object.isAvatar ? nil : object.appearance?.basicPrimitive
        let mesh: MeshResource
        switch primitive {
        case .cylinder: mesh = cylinder
        default: mesh = box
        }
        var material = object.isAvatar ? avatarMaterial : objectMaterial
        // Texture maps and per-face materials still need the asset pipeline. Use the
        // default tint only for recognized primitives; keep unsupported bounds distinct.
        if primitive != nil, let tint = object.appearance?.faces.first?.color {
            material = UnlitMaterial(color: .init(red: CGFloat(tint.x), green: CGFloat(tint.y),
                                                  blue: CGFloat(tint.z), alpha: CGFloat(tint.w)))
        }
        let model = ModelEntity(mesh: mesh, materials: [material])
        if primitive == .cylinder {
            // RealityKit cylinders use Y-up; simulator primitives use Z-up.
            model.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        }
        return model
    }

    private func convert(_ position: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(position.x, position.z, -position.y)
    }
}
