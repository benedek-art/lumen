import Foundation
import CoreImage
import CoreGraphics
import LumenCore
import LumenPipeline
let working=CGColorSpace(name:CGColorSpace.extendedLinearITUR_2020)!
let context=CIContext(options:[.workingColorSpace:working,.workingFormat:CIFormat.RGBAf,.cacheIntermediates:false])
func triple(_ c:RGB)->[Double]{[c.r,c.g,c.b]}
func probe(_ name:String,_ c:RGB,_ change:(inout Recipe)->Void) {
 var r=Recipe();r.develop.denoise.mode = .off;change(&r)
 for size in [33,65] {
  let p=RenderPlan(recipe:r,lutSize:size)
  let pixels:[Float]=[Float(c.r),Float(c.g),Float(c.b),1]
  let data=pixels.withUnsafeBufferPointer{Data(buffer:$0)}
  let source=CIImage(bitmapData:data,bytesPerRow:16,size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:working)
  let output=RenderGraph().build(source,plan:p,options:RenderGraph.Options(longEdge:1))
  var bytes=[Float](repeating:0,count:4)
  context.render(output,toBitmap:&bytes,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:working)
  let exact=p.exactColor(c);let gpu=RGB(Double(bytes[0]),Double(bytes[1]),Double(bytes[2]))
  let v:[String:Any]=["setting":name,"lutSize":size,"input":triple(c),"exact":triple(exact),"referenceTable":triple(p.referenceColor(c)),"gpu":triple(gpu),"maxCodeError":255*TransferFunction.srgb.encode(exact).maxAbsDifference(TransferFunction.srgb.encode(gpu))]
  print(String(data:try! JSONSerialization.data(withJSONObject:v,options:[.sortedKeys]),encoding:.utf8)!)
 }
}
probe("aqua_lum-100",RGB(0.38413364324424248,0.59591710513566343,0.64828909901873966)){$0.develop.mixer.bands[4].lum = -100}
probe("saturation100",RGB(0.78994447795661316,0.51750730037644888,0.21031789665386302)){$0.develop.color.saturation=100}
probe("luma_black_lift",RGB(gray:1e-8)){$0.develop.curve.luma=[[0,0.2],[1,1]]}
