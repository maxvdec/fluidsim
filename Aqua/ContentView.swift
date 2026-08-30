import Playgrounds
import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct IntField: View {
    @Binding var value: Int

    let title: String
    let unit: String

    @State private var text: String = ""

    init(
        _ title: String,
        value: Binding<Int>,
        unit: String
    ) {
        self.title = title
        self._value = value
        self.unit = unit
    }

    var body: some View {
        HStack {
            Text(title)

            Spacer()

            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { _, newValue in
                    if let number = Int(newValue) {
                        value = number
                    }
                }

            Text(unit)
                .foregroundStyle(.secondary)
                .frame(minWidth: 35, alignment: .leading)
        }
        .onAppear {
            text = format(value)
        }
        .onChange(of: value) { _, newValue in
            if Int(text) != newValue {
                text = format(newValue)
            }
        }
    }

    private func format(_ value: Int) -> String {
        String(value)
    }
}

struct FloatField: View {
    @Binding var value: Float

    let title: String
    let unit: String
    let isZeroPermitted: Bool

    @State private var text: String = ""

    init(
        _ title: String,
        value: Binding<Float>,
        unit: String,
        isZeroPermitted: Bool = false
    ) {
        self.title = title
        self._value = value
        self.unit = unit
        self.isZeroPermitted = isZeroPermitted
    }

    var body: some View {
        HStack {
            Text(title)

            Spacer()

            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { _, newValue in
                    if let number = Float(newValue) {
                        if number == 0 && !isZeroPermitted {
                            return
                        }
                        value = number
                    }
                }

            Text(unit)
                .foregroundStyle(.secondary)
                .frame(minWidth: 35, alignment: .leading)
        }
        .onAppear {
            text = format(value)
        }
        .onChange(of: value) { _, newValue in
            if Float(text) != newValue {
                text = format(newValue)
            }
        }
    }

    private func format(_ value: Float) -> String {
        String(format: "%.3g", value)
    }
}

struct ParametersView: View {
    @Binding var settings: SimulationSettings
    @State private var wantsMouse: Bool = true

    var body: some View {
        HStack {
            Spacer()
            RoundedRectangle(cornerRadius: 16)
                .frame(maxWidth: 300, maxHeight: .infinity)
                .foregroundStyle(.white)
                .overlay {
                    HStack {
                        parameterList
                            .padding()
                        Spacer()
                    }
                }
                .padding()
        }.padding()
    }

    var parameterList: some View {
        VStack {
            Text("Parameters")
                .font(.largeTitle)
                .bold()

            FloatField("Gravity", value: $settings.gravity, unit: "m/s2", isZeroPermitted: true)
            HStack {
                Text("Smoothing Radius: ")
                Slider(value: $settings.smoothingRadius, in: 0.1 ... 10.0)
                Text(settings.smoothingRadius.formatted(.number.precision(.fractionLength(2))))
            }
            HStack {
                Text("Target Density")
                Slider(value: $settings.targetDensity, in: 1 ... 500)
                Text(settings.targetDensity.formatted(.number.precision(.fractionLength(2))))
            }
            FloatField("Pressure Multiplier", value: $settings.pressureMultiplier, unit: "")
            FloatField("Near Pressure Multiplier", value: $settings.nearPressureMultiplier, unit: "")
            FloatField("Viscosity Strength", value: $settings.viscosityStrength, unit: "")
            FloatField("Particle Mass", value: $settings.particleMass, unit: "")
            Divider()
            FloatField("Bounds X", value: $settings.boundsX, unit: "m")
            FloatField("Bounds Y", value: $settings.boundsY, unit: "m")
            FloatField("Bounds Z", value: $settings.boundsZ, unit: "m")
            VStack(alignment: .leading) {
                Text("Boundary Viewport Padding")
                HStack {
                    Slider(value: $settings.boundaryViewportPadding, in: -50 ... 45)
                    Text(settings.boundaryViewportPadding.formatted(.number.precision(.fractionLength(0))))
                    Text("%")
                        .foregroundStyle(.secondary)
                }
                Text(boundaryViewportPaddingDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            IntField("Particles", value: $settings.particles, unit: "part.")
            HStack {
                Text("Particle Radius: ")
                Slider(value: $settings.particleRadius, in: 0.001 ... 1.0)
            }
            HStack {
                Text("Particle Spacing: ")
                Slider(value: $settings.particleSpacing, in: 0.001 ... 0.3)
            }
            Toggle(isOn: $settings.randomScattering) {
                Text("Scatter randomly")
            }
            Divider()
            FloatField("Mouse Radius", value: $settings.mouseRadius, unit: "")
            FloatField("Mouse Strength", value: $settings.mouseStrength, unit: "")
            Toggle(isOn: $wantsMouse) {
                Text("Mouse Activated")
            }
            Text("Drag to grab • Shift-drag to repel • Right-drag to orbit • Scroll to zoom or adjust grab depth")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            
            
            Spacer()
            Button {
                settings.paused.toggle()
            } label: {
                if settings.paused {
                    Image(systemName: "play")
                } else {
                    Image(systemName: "pause")
                }
            }
        }
        .onChange(of: wantsMouse) {
            if (wantsMouse == true) {
                settings.mouseStrength = 20.0
            } else {
                settings.mouseStrength = 0.0
            }
        }
    }

    private var boundaryViewportPaddingDescription: String {
        if settings.boundaryViewportPadding < 0 {
            return "Boundary larger than screen"
        }

        if settings.boundaryViewportPadding > 0 {
            return "Boundary smaller than screen"
        }

        return "Boundary fits screen"
    }
}

struct ContentView: View {
    @State private var settings = SimulationSettings()
    @State private var renderer: Renderer

    init() {
        let settings = SimulationSettings()

        _settings = State(initialValue: settings)
        _renderer = State(initialValue: Renderer(settings: settings))
    }

    var body: some View {
        VStack {
            MetalView(renderer: renderer)
        }
        .overlay {
            ParametersView(settings: $settings)
        }
    }
}
