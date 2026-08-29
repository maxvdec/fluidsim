import Playgrounds
import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct FloatField: View {
    @Binding var value: Float

    let title: String
    let unit: String

    @State private var text: String = ""

    init(
        _ title: String,
        value: Binding<Float>,
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
                    if let number = Float(newValue) {
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

            HStack {
                Text("Particle Size: ")
                Slider(value: $settings.particleSize, in: 0.1 ... 30.0)
            }
            
            FloatField("Gravity", value: $settings.gravity, unit: "m/s2")
            
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
