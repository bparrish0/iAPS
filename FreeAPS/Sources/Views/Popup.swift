import SwiftUI

struct Popup<T: View>: ViewModifier {
    let popup: T
    let isPresented: Bool
    let alignment: Alignment
    let direction: Direction
    let type: Animation

    init(isPresented: Bool, alignment: Alignment, direction: Direction, type: Animation, @ViewBuilder content: () -> T) {
        self.isPresented = isPresented
        self.alignment = alignment
        self.direction = direction
        self.type = type
        popup = content()
    }

    func body(content: Content) -> some View {
        content
            .overlay(popupContent())
    }

    @ViewBuilder private func popupContent() -> some View {
        GeometryReader { geometry in
            if isPresented {
                popup
                    .animation(type)
                    .transition(.offset(x: 0, y: direction.offset(containerHeight: geometry.size.height)))
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: alignment)
            }
        }
    }
}

extension Popup {
    enum Direction {
        case top
        case bottom
        case center

        func offset(containerHeight: CGFloat) -> CGFloat {
            switch self {
            case .top:
                return -containerHeight
            case .bottom:
                return containerHeight
            case .center:
                return containerHeight / 2
            }
        }
    }
}

extension View {
    func popup<T: View>(
        isPresented: Bool,
        alignment: Alignment = .center,
        direction: Popup<T>.Direction = .bottom,
        type: Animation = .spring,
        @ViewBuilder content: () -> T
    ) -> some View {
        modifier(Popup(isPresented: isPresented, alignment: alignment, direction: direction, type: type, content: content))
    }
}
