Module M0.

Module M1.

Inductive I1 := 
| I11: I1
| I12: I1.

Section S11.

Variable a b: I1.

Lemma eqI1: a = a.
Proof.
  reflexivity.
Qed.

End S11.

Lemma eqI2: forall (x: I1), x=x.
Proof.
apply eqI1.
Qed.

Module M11.

Lemma eqI3: forall (x: I1), x=x.
Proof.
apply eqI1.
Qed.

End M11.

End M1.

Module M2.

Lemma eqI4: forall (x: M1.I1), x=x.
Proof.
apply M1.M11.eqI3.
Qed.

End M2.

End M0.

