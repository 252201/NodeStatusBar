//
//  ContentView.swift
//  NodeStatusBar
//
//  Created by LPP on 2026/6/2.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("NodeStatusBar")
                .font(.title2.weight(.semibold))
            Text("节点状态会显示在 macOS 菜单栏。")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
