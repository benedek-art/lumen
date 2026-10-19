import Foundation
import LumenCore
for (mode, amount) in [("relative",1.0),("relative",100.0),("absolute",1.0)] {
 var a=LocalAdjust();if mode=="relative"{a.temp=20;a.tint=13}else{a.kelvin=3200;a.kelvinTint=17}
 let b=ReferenceRenderer.LocalWhiteBalance.resolve(a,amount:amount/100,
  balanced:WhiteBalanceEngine.Neutral(kelvin:5500,tint:0),space:.rec2020)
 let inputs=[RGB(-0.01,0.18,0.3),RGB(0.18,0.3,0.5),RGB(1024,128,256)]
 var values:[[String:Any]]=[]
 for c in inputs {
  let float = Mat3(b.matrix.m.map{$0.map{Double(Float($0))}})
  let trimmed = Mat3(b.matrix.m.enumerated().map{r,row in row.enumerated().map{col,v in r != col && abs(v)<0.0001 ? 0:v}})
  let actual=b.apply(c),f=float.apply(c),t=trimmed.apply(c)
  values.append(["input":[c.r,c.g,c.b],"direct":[actual.r,actual.g,actual.b],"FloatCoefficients":[f.r,f.g,f.b],"trimmedSmallOffDiagonal":[t.r,t.g,t.b]])
 }
 let row:[String:Any]=["mode":mode,"amount":amount,"matrix":b.matrix.m,"values":values]
 let data=try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]);var line=data;line.append(10);FileHandle.standardOutput.write(line)
}
