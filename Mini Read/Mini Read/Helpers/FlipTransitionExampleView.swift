//
//  ContentView.swift
//  FWTransition
//
//  Created by Balaji Venkatesh on 28/08/26.
//

import SwiftUI

struct FlipTransitionExampleView: View {
    var body: some View {
        
        ScrollView(.vertical) {
            Grid {
                GridRow {
                    FlipTransition {
                        DummyLabel(
                            title: "Distance",
                            subtitle: "Today",
                            highlight: "0.54KM",
                            highlightColor: .cyan
                        )
                    } destination: { dismiss in
                        DummyDestination(symbol: "figure.walk", title: "Distance")
                    } contextActions: {

                    }

                    FlipTransition {
                        DummyLabel(
                            title: "Step Count",
                            subtitle: "Today",
                            highlight: "707",
                            highlightColor: .indigo
                        )
                    } destination: { dismiss in
                        DummyDestination(symbol: "shoeprints.fill", title: "Step Count")
                    } contextActions: {

                    }
                }

                FlipTransition {
                    DummyLabel(
                        title: "Sessions",
                        subtitle: "Indoor Walk",
                        highlight: "2.28KM",
                        highlightColor: .green
                    )
                } destination: { dismiss in
                    DummyDestination(symbol: "figure.indoor.walk", title: "Sessions")
                } contextActions: {

                }
            }
            .padding(15)
        }
        .navigationTitle("Summary")
        .toolbarTitleDisplayMode(.inlineLarge)
        
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

struct DummyLabel: View {
    var title: String
    var subtitle: String
    var highlight: String
    var highlightColor: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.gray.secondary)
            }

            Text(subtitle)
                .font(.callout)

            Text(highlight)
                .font(.title)
                .fontWeight(.medium)
                .foregroundStyle(highlightColor)

            HStack {
                Text("12 AM")
                Spacer(minLength: 0)
                Text("6 AM")
                Spacer(minLength: 0)
                Text("12 PM")
                Spacer(minLength: 0)
                Text("6 PM")
            }
            .font(.caption2)
            .foregroundStyle(.gray)
            .padding(.top, 40)
        }
        .padding(15)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.systemGray6))
        }
    }
}

struct DummyDestination: View {
    var symbol: String
    var title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer(minLength: 0)

                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.gray.secondary)
            }

            Text("Today")
                .font(.callout)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Tap outside to flip back")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
