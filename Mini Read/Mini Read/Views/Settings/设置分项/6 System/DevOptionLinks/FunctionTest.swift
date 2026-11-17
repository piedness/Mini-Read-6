//
//  FunctionTest.swift
//  Vellium
//
//  Created by piednes on 25/04/2025.
//

import SwiftUI
import SwiftData

struct FunctionTestView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [ SortDescriptor(\bookItem.dateAdded, order: .reverse) ]
    ) private var items: [bookItem]
    
    @State private var coverURLs: [URL]? = nil
    
    var body: some View {
        NavigationLink("Function Test"){
            List{
                NavigationLink("Parse Function"){
                    List{
                        ForEach(items) { item in
                            NavigationLink {
                                List{
                                    cover()
                                    Text("标题：\(item.bookTitle)")
                                    Text("导入时间：\(item.dateAdded, format: Date.FormatStyle(date: .numeric, time: .standard))")
                                    Text("作者：\(item.bookAuthor)")
                                    Text("出版社：\(item.bookPublisher)")
                                    Text("EPUB文件解压路径：\(item.bookExtrSubdir)")


                                    
                                    
                                }
                                .modifier(CustomListModifier(title: item.bookTitle))
                                .onAppear{loadEpubCover(bookExtrSubdir: item.bookExtrSubdir)}
                            } label: {
                                Text(item.bookTitle)
                            }
                        }
                    }
                    .modifier(CustomListModifier(title: "Parse Function"))
                }
            }
            .modifier(CustomListModifier(title: "Function Test"))
        }
    }
    
    private func loadEpubCover(bookExtrSubdir: URL){

        let epubBook = EPUBBook(contentsOf: bookExtrSubdir)
        if let coverImageURLs = epubBook?.coverImageURLs{
            coverURLs = coverImageURLs
        }
    }
    
    @ViewBuilder
    func cover()-> some View{
        VStack{
            if let firstURL = coverURLs?.first,  // 解包数组并取第一张图片的URL
               let uiImage = UIImage(contentsOfFile: firstURL.path) {
                VStack{
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: 5))
                        .shadow(radius: 10)
                        .frame(width: 160,height: 240)
                    }
            }
        }
    }
    
}
