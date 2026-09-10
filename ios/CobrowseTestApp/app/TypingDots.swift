//
//  TypingDots.swift
//  CobrowseTestApp
//
//  Индикатор «печатает»: три точки, по очереди подсвечиваются. Без таймеров и
//  @State — фазу считает TimelineView по часам, поэтому индикатор можно
//  показывать сразу в нескольких местах (FAB, экран чата) без рассинхрона.
//

import SwiftUI

struct TypingDots: View {
    var color: Color = .primary
    var dotSize: CGFloat = 6
    var spacing: CGFloat = 3

    /// Шаг смены активной точки.
    private let step: TimeInterval = 0.3

    var body: some View {
        TimelineView(.periodic(from: .now, by: step)) { context in
            let phase = Int((context.date.timeIntervalSinceReferenceDate / step).rounded(.down)) % 3
            HStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(color)
                        .frame(width: dotSize, height: dotSize)
                        .opacity(i == phase ? 1 : 0.3)
                        .scaleEffect(i == phase ? 1.15 : 1)
                }
            }
            .animation(.easeInOut(duration: step * 0.8), value: phase)
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 24) {
        TypingDots()
        TypingDots(color: .white, dotSize: 5, spacing: 2.5)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Capsule().fill(.black))
    }
    .padding()
}
