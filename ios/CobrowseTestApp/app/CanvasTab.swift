//
//  CanvasTab.swift
//  CobrowseTestApp
//
//  Свободное рисование пальцем — проверяет отзывчивость gesture-ввода
//  через стрим (важно: latency на touch input ≠ latency на видео).
//
//  Требует iOS 15+ (Canvas API).
//

import SwiftUI

struct CanvasTab: View {
    @State private var strokes: [Stroke] = []
    @State private var currentStroke: Stroke?
    @State private var color: Color = .blue
    @State private var lineWidth: Double = 4

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Toolbar(color: $color, lineWidth: $lineWidth, strokeCount: strokes.count) {
                    strokes.removeAll()
                    currentStroke = nil
                }

                Canvas { ctx, size in
                    for stroke in strokes {
                        drawStroke(stroke, in: &ctx)
                    }
                    if let s = currentStroke {
                        drawStroke(s, in: &ctx)
                    }
                }
                .background(Color(.systemBackground))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if currentStroke == nil {
                                currentStroke = Stroke(color: color, lineWidth: lineWidth, points: [value.location])
                            } else {
                                currentStroke?.points.append(value.location)
                            }
                        }
                        .onEnded { _ in
                            if let s = currentStroke { strokes.append(s) }
                            currentStroke = nil
                        }
                )
            }
            .navigationTitle("Рисование")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }

    private func drawStroke(_ stroke: Stroke, in ctx: inout GraphicsContext) {
        var path = Path()
        guard let first = stroke.points.first else { return }
        path.move(to: first)
        for point in stroke.points.dropFirst() {
            path.addLine(to: point)
        }
        ctx.stroke(
            path,
            with: .color(stroke.color),
            style: StrokeStyle(lineWidth: stroke.lineWidth, lineCap: .round, lineJoin: .round)
        )
    }
}

// MARK: - Stroke model

private struct Stroke: Identifiable {
    let id = UUID()
    let color: Color
    let lineWidth: Double
    var points: [CGPoint]
}

// MARK: - Toolbar

private struct Toolbar: View {
    @Binding var color: Color
    @Binding var lineWidth: Double
    let strokeCount: Int
    let onClear: () -> Void

    private let palette: [Color] = [.blue, .red, .green, .orange, .purple, .black]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ForEach(palette, id: \.self) { c in
                    Circle()
                        .fill(c)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(.primary, lineWidth: color == c ? 3 : 0))
                        .onTapGesture { color = c }
                }
                Spacer()
                Text("\(strokeCount) штрихов")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Толщина")
                    .font(.caption)
                Slider(value: $lineWidth, in: 1...20)
                Text("\(Int(lineWidth))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 24)

                Button(action: onClear) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(strokeCount == 0)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
    }
}

#Preview {
    CanvasTab()
}
