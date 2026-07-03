//
//  AnimationTab.swift
//  CobrowseTestApp
//
//  Экраны для проверки:
//    - плавность видео-стрима (bouncing ball, вращающийся градиент)
//    - латентность (frame counter — можно снять скриншот с двух устройств и сравнить)
//    - синхронизация часов (миллисекундный timestamp)
//
//  Требует iOS 15+ (TimelineView.animation, Canvas).
//

import SwiftUI

struct AnimationTab: View {
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    LiveClockCard()
                    FrameCounterCard()
                    BouncingBallCard()
                    RotatingGradientCard()
                    MovingStripeCard()
                }
                .padding()
                .padding(.top, 40) // отступ под REC-badge
            }
            .navigationTitle("Движение")
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Live Clock

/// Живые часы с миллисекундами — ставим напротив web-agent и визуально
/// оцениваем end-to-end latency.
private struct LiveClockCard: View {
    var body: some View {
        Card(title: "Живые часы", subtitle: "Латентность видна невооружённым глазом") {
            TimelineView(.periodic(from: .now, by: 0.033)) { context in
                Text(formatted(context.date))
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
}

// MARK: - Frame counter

/// Счётчик кадров. Каждый вызов TimelineView(.animation) — новый frame.
/// Полезно для точной сверки: скриншот iOS + скриншот браузера, сравнить числа.
private struct FrameCounterCard: View {
    var body: some View {
        Card(title: "Frame counter", subtitle: "TimelineView(.animation) — 60 fps target") {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
                let n = Int(context.date.timeIntervalSinceReferenceDate * 60) % 100000
                Text("\(n)")
                    .font(.system(size: 44, weight: .heavy, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.blue)
            }
        }
    }
}

// MARK: - Bouncing ball

private struct BouncingBallCard: View {
    var body: some View {
        Card(title: "Мяч", subtitle: "Плавность движения — базовая проверка fps") {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = sin(t * 2.5)
                let x = 20 + (phase + 1) / 2 * 260
                let y = abs(sin(t * 5)) * 20
                Canvas { ctx, size in
                    let rect = CGRect(x: x, y: 60 - y, width: 40, height: 40)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.red))
                }
                .frame(height: 100)
            }
        }
    }
}

// MARK: - Rotating gradient

private struct RotatingGradientCard: View {
    var body: some View {
        Card(title: "Градиент", subtitle: "Тестирует цветовую точность и полосу") {
            TimelineView(.animation) { context in
                let angle = context.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 6) / 6 * 360
                AngularGradient(
                    gradient: Gradient(colors: [.purple, .pink, .orange, .yellow, .green, .blue, .purple]),
                    center: .center,
                    angle: .degrees(angle)
                )
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// MARK: - Moving stripe

/// Полоса движется с известной скоростью — если на устройствах видны рывки
/// или неравномерное движение, значит есть frame drops.
private struct MovingStripeCard: View {
    var body: some View {
        Card(title: "Полоса", subtitle: "Известная скорость — видно drops и джиттер") {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = t.truncatingRemainder(dividingBy: 4) / 4
                Canvas { ctx, size in
                    let stripeWidth: CGFloat = 60
                    let x = CGFloat(phase) * size.width
                    let rect = CGRect(x: x - stripeWidth, y: 0, width: stripeWidth, height: size.height)
                    ctx.fill(Path(rect), with: .color(.black))
                }
                .frame(height: 40)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Reusable card

private struct Card<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            content()
                .padding(.top, 4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    AnimationTab()
}
